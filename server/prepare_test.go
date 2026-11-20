package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeBuilder writes small files instead of running the real tools. Each
// build waits on release (when set), so a test can look at a job mid-run.
type fakeBuilder struct {
	dir      string
	release  chan struct{}
	failMap  bool
	failPois bool
	maps     atomic.Int32
}

func (b *fakeBuilder) BuildMap(_ context.Context, r CatalogRegion) error {
	b.maps.Add(1)
	part := filepath.Join(b.dir, r.ID+".pmtiles.part")
	if err := os.WriteFile(part, make([]byte, 500), 0o644); err != nil {
		return err
	}
	if b.release != nil {
		<-b.release
	}
	if b.failMap {
		return errors.New("planet build unreachable")
	}
	return os.Rename(part, filepath.Join(b.dir, r.ID+".pmtiles"))
}

func (b *fakeBuilder) BuildPois(_ context.Context, r CatalogRegion) error {
	if b.failPois {
		return errors.New("overpass busy")
	}
	return os.WriteFile(filepath.Join(b.dir, r.ID+".pois.json"), []byte(`{"pois":[]}`), 0o644)
}

var testCatalog = map[string]CatalogRegion{
	"sarnia": {ID: "sarnia", Level: "city", ApproxBytes: 1000},
	"mexico": {ID: "mexico", Level: "country", ApproxBytes: 2000},
	"europe": {ID: "europe", Level: "continent", ApproxBytes: 46_000_000_000},
	"world":  {ID: "world", Level: "world", ApproxBytes: 1, RemoteURL: "https://example.org/planet.pmtiles"},
}

func newPreparer(t *testing.T, b *fakeBuilder) *Preparer {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return NewPreparer(ctx, b.dir, testCatalog, b, 10_000)
}

// waitFor polls the job until it leaves the queued/running states.
func waitFor(t *testing.T, p *Preparer, id string) Job {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if job, _ := p.Status(id); job.State == JobDone || job.State == JobFailed {
			return job
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("job %s did not finish", id)
	return Job{}
}

func TestPrepareBuildsMapAndSupplies(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir()}
	p := newPreparer(t, b)

	if _, err := p.Start("sarnia"); err != nil {
		t.Fatal(err)
	}
	job := waitFor(t, p, "sarnia")
	if job.State != JobDone || job.Note != "" || job.BytesDone != job.BytesTotal {
		t.Fatalf("job = %+v", job)
	}
	for _, name := range []string{"sarnia.pmtiles", "sarnia.pois.json"} {
		if _, err := os.Stat(filepath.Join(b.dir, name)); err != nil {
			t.Errorf("%s missing: %v", name, err)
		}
	}
}

func TestPrepareReportsProgressFromThePartialFile(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir(), release: make(chan struct{})}
	p := newPreparer(t, b)
	p.Start("sarnia")

	deadline := time.Now().Add(5 * time.Second)
	for {
		job, _ := p.Status("sarnia")
		if job.State == JobRunning && job.BytesDone == 500 {
			break // 500 of 1000 bytes written: half way
		}
		if time.Now().After(deadline) {
			t.Fatalf("never saw progress; last %+v", job)
		}
		time.Sleep(5 * time.Millisecond)
	}
	close(b.release)
	waitFor(t, p, "sarnia")
}

func TestPrepareIsIdempotentWhileRunning(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir(), release: make(chan struct{})}
	p := newPreparer(t, b)
	p.Start("sarnia")
	p.Start("sarnia")
	close(b.release)
	waitFor(t, p, "sarnia")
	if n := b.maps.Load(); n != 1 {
		t.Fatalf("built %d times, want 1", n)
	}
}

func TestPrepareSkipsWhatIsAlreadyHosted(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir()}
	os.WriteFile(filepath.Join(b.dir, "sarnia.pmtiles"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(b.dir, "sarnia.pois.json"), []byte("{}"), 0o644)
	p := newPreparer(t, b)

	job, err := p.Start("sarnia")
	if err != nil || job.State != JobDone {
		t.Fatalf("job = %+v, err = %v", job, err)
	}
	if b.maps.Load() != 0 {
		t.Fatal("rebuilt a hosted region")
	}
}

func TestPrepareRetriesOnlyAMissingSupplyList(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir()}
	os.WriteFile(filepath.Join(b.dir, "sarnia.pmtiles"), []byte("x"), 0o644)
	p := newPreparer(t, b)

	p.Start("sarnia")
	if job := waitFor(t, p, "sarnia"); job.State != JobDone || job.Note != "" {
		t.Fatalf("job = %+v", job)
	}
	if b.maps.Load() != 0 {
		t.Fatal("rebuilt the map when only the supply list was missing")
	}
	if _, err := os.Stat(filepath.Join(b.dir, "sarnia.pois.json")); err != nil {
		t.Fatal("supply list not built")
	}
}

func TestPrepareRefusesWhatItShouldNotBuild(t *testing.T) {
	p := newPreparer(t, &fakeBuilder{dir: t.TempDir()})
	for id, want := range map[string]error{
		"atlantis": errUnknownRegion,
		"europe":   errTooBig,
		"world":    errStreamed,
	} {
		if _, err := p.Start(id); !errors.Is(err, want) {
			t.Errorf("Start(%s) = %v, want %v", id, err, want)
		}
	}
}

func TestPrepareFailureCanBeRetried(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir(), failMap: true}
	p := newPreparer(t, b)
	p.Start("sarnia")
	if job := waitFor(t, p, "sarnia"); job.State != JobFailed || !strings.Contains(job.Error, "unreachable") {
		t.Fatalf("job = %+v", job)
	}
	if _, ok := p.Active()["sarnia"]; !ok {
		t.Error("a failed job should stay listed so the app can show why")
	}

	b.failMap = false
	p.Start("sarnia")
	if job := waitFor(t, p, "sarnia"); job.State != JobDone {
		t.Fatalf("retry: %+v", job)
	}
}

func TestPrepareWithoutSuppliesStillSucceeds(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir(), failPois: true}
	p := newPreparer(t, b)
	p.Start("sarnia")
	if job := waitFor(t, p, "sarnia"); job.State != JobDone || !strings.Contains(job.Note, "supply list") {
		t.Fatalf("job = %+v", job)
	}

	// Countries never get a supply pack: Overpass can't answer that big an area.
	p.Start("mexico")
	if job := waitFor(t, p, "mexico"); job.State != JobDone || job.Note == "" {
		t.Fatalf("mexico = %+v", job)
	}
}

func TestPrepareEndpoints(t *testing.T) {
	b := &fakeBuilder{dir: t.TempDir()}
	s := &Server{store: NewMemoryStore(), regionsDir: b.dir, preparer: newPreparer(t, b)}
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(ts.Close)

	resp, err := http.Post(ts.URL+"/regions/sarnia/prepare", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if job := decode[Job](t, resp); resp.StatusCode != http.StatusAccepted || job.RegionID != "sarnia" {
		t.Fatalf("POST: %d %+v", resp.StatusCode, job)
	}
	waitFor(t, s.preparer, "sarnia")

	resp, _ = http.Get(ts.URL + "/regions/sarnia/prepare")
	if job := decode[Job](t, resp); job.State != JobDone {
		t.Fatalf("GET: %+v", job)
	}

	resp, _ = http.Post(ts.URL+"/regions/europe/prepare", "", nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("europe: %d", resp.StatusCode)
	}

	resp, _ = http.Get(ts.URL + "/regions/index.json")
	index := decode[struct {
		Regions map[string]any `json:"regions"`
		Prepare struct {
			Enabled  bool  `json:"enabled"`
			MaxBytes int64 `json:"maxBytes"`
		} `json:"prepare"`
	}](t, resp)
	if _, ok := index.Regions["sarnia"]; !ok || !index.Prepare.Enabled || index.Prepare.MaxBytes != 10_000 {
		t.Fatalf("index = %+v", index)
	}
}
