package main

// On-demand region preparation.
//
// The catalog shipped in the app lists 80 regions, from a city to the whole
// planet. A production deployment would build every one ahead of time in a
// pipeline and put the files on object storage. The dev server can't host
// all of them up front, so instead it builds a region the first time someone
// asks for it, using the same tools a developer runs by hand:
//
//	tool/fetch_region.py  cuts the basemap out of the Protomaps planet build
//	tool/import_pois.py   pulls the supply locations from Overpass
//	tool/build_routing.py compiles the road and rail network for directions
//
// Jobs run one at a time: each is bandwidth-bound, so running two at once
// would only make both slower. Both tools write to "<file>.part" and rename
// when complete, so the file server (which only serves complete names) never
// hands out half a region.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// CatalogRegion is the part of an assets/regions/catalog.json entry the
// server needs.
type CatalogRegion struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Level       string     `json:"level"`
	BBox        [4]float64 `json:"bbox"`
	ApproxBytes int64      `json:"approxBytes"`
	RemoteURL   string     `json:"remoteUrl"`
}

// LoadCatalog reads the app's region catalog, keyed by id.
func LoadCatalog(path string) (map[string]CatalogRegion, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var file struct {
		Regions []CatalogRegion `json:"regions"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	byID := make(map[string]CatalogRegion, len(file.Regions))
	for _, r := range file.Regions {
		byID[r.ID] = r
	}
	return byID, nil
}

// JobState is where one preparation job stands.
type JobState string

const (
	JobQueued  JobState = "queued"
	JobRunning JobState = "running"
	JobDone    JobState = "done"
	JobFailed  JobState = "failed"
)

// Job is the JSON the app polls while a region is being prepared.
type Job struct {
	RegionID string   `json:"regionId"`
	State    JobState `json:"state"`
	// Step is "map", "supplies" or "routes" while running.
	Step string `json:"step,omitempty"`
	// BytesDone counts the basemap written so far; BytesTotal is the
	// catalog's measured size, so the ratio is a real progress fraction.
	BytesDone  int64  `json:"bytesDone"`
	BytesTotal int64  `json:"bytesTotal"`
	Error      string `json:"error,omitempty"`
	// Note explains a partial success, e.g. a map without a supply list.
	Note string `json:"note,omitempty"`
}

// Builder produces a region's files in the regions directory. The real one
// runs the repo's tools; tests substitute a fake.
type Builder interface {
	// BuildMap writes <dir>/<id>.pmtiles, via <id>.pmtiles.part.
	BuildMap(ctx context.Context, region CatalogRegion) error
	// BuildPois writes <dir>/<id>.pois.json.
	BuildPois(ctx context.Context, region CatalogRegion) error
	// BuildRoutes writes <dir>/<id>.routing.bin.
	BuildRoutes(ctx context.Context, region CatalogRegion) error
}

var (
	errUnknownRegion = errors.New("unknown region")
	errTooBig        = errors.New("too big to prepare on demand")
	errStreamed      = errors.New("this region streams from its own source")
)

// Preparer queues and runs preparation jobs.
type Preparer struct {
	dir      string
	catalog  map[string]CatalogRegion
	builder  Builder
	maxBytes int64

	mu    sync.Mutex
	jobs  map[string]*Job
	queue chan string
}

// NewPreparer starts the worker; it stops when ctx is cancelled.
func NewPreparer(ctx context.Context, dir string, catalog map[string]CatalogRegion, builder Builder, maxBytes int64) *Preparer {
	p := &Preparer{
		dir: dir, catalog: catalog, builder: builder, maxBytes: maxBytes,
		jobs:  map[string]*Job{},
		queue: make(chan string, len(catalog)+1),
	}
	go p.work(ctx)
	return p
}

// MaxBytes is the largest region this server will prepare.
func (p *Preparer) MaxBytes() int64 { return p.maxBytes }

// Start queues a job for id, or returns the one already queued or running.
// Asking again after a failure retries. Asking for a region that is already
// hosted reports it as done without rebuilding.
func (p *Preparer) Start(id string) (Job, error) {
	region, ok := p.catalog[id]
	switch {
	case !ok:
		return Job{}, errUnknownRegion
	case region.RemoteURL != "":
		return Job{}, errStreamed
	case region.ApproxBytes > p.maxBytes:
		return Job{}, errTooBig
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if job, ok := p.jobs[id]; ok && (job.State == JobQueued || job.State == JobRunning) {
		return p.snapshot(job), nil
	}
	if p.complete(region) {
		return Job{RegionID: id, State: JobDone, BytesDone: region.ApproxBytes, BytesTotal: region.ApproxBytes}, nil
	}
	job := &Job{RegionID: id, State: JobQueued, BytesTotal: region.ApproxBytes}
	p.jobs[id] = job
	p.queue <- id
	return p.snapshot(job), nil
}

// Status reports the job for id. ok is false when there has been no job.
func (p *Preparer) Status(id string) (job Job, ok bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	j, ok := p.jobs[id]
	if !ok {
		return Job{}, false
	}
	return p.snapshot(j), true
}

// Active lists jobs that are queued, running or failed, for index.json, so
// an app that restarts mid-job can pick the progress back up.
func (p *Preparer) Active() map[string]Job {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := map[string]Job{}
	for id, j := range p.jobs {
		if j.State != JobDone {
			out[id] = p.snapshot(j)
		}
	}
	return out
}

// snapshot copies a job, filling in live progress from the partial file.
// Callers hold p.mu.
func (p *Preparer) snapshot(j *Job) Job {
	out := *j
	if j.State == JobRunning && j.Step == "map" {
		if info, err := os.Stat(filepath.Join(p.dir, j.RegionID+".pmtiles.part")); err == nil {
			// The measured size is rounded to two significant figures, so
			// never report more than 99% until the job says it's done.
			out.BytesDone = min(info.Size(), j.BytesTotal*99/100)
		}
	}
	return out
}

func (p *Preparer) exists(name string) bool {
	_, err := os.Stat(filepath.Join(p.dir, name))
	return err == nil
}

// wantsSupplies: Overpass answers city- and province-sized queries;
// anything larger times out, so those regions ship as a map alone.
func wantsSupplies(region CatalogRegion) bool {
	return region.Level == "city" || region.Level == "province"
}

// wantsRoutes: a road network only comes back from Overpass for a city.
// Provinces and up need a planet-file pipeline (osmium), not built yet.
func wantsRoutes(region CatalogRegion) bool {
	return region.Level == "city"
}

// complete is true when nothing is left to build. A map whose supply list
// or routing pack failed earlier (Overpass is a shared, sometimes overloaded
// service) is not complete, so asking again retries just what is missing.
func (p *Preparer) complete(region CatalogRegion) bool {
	return p.exists(region.ID+".pmtiles") &&
		(!wantsSupplies(region) || p.exists(region.ID+".pois.json")) &&
		(!wantsRoutes(region) || p.exists(region.ID+".routing.bin"))
}

func (p *Preparer) work(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case id := <-p.queue:
			p.run(ctx, p.catalog[id])
		}
	}
}

func (p *Preparer) run(ctx context.Context, region CatalogRegion) {
	if p.exists(region.ID + ".pmtiles") {
		log.Printf("prepare %s: map already built", region.ID)
	} else {
		p.update(region.ID, func(j *Job) { j.State, j.Step = JobRunning, "map" })
		log.Printf("prepare %s: building map (~%d MB)", region.ID, region.ApproxBytes/1e6)
		if err := p.builder.BuildMap(ctx, region); err != nil {
			log.Printf("prepare %s: map failed: %v", region.ID, err)
			p.update(region.ID, func(j *Job) { j.State, j.Step, j.Error = JobFailed, "", err.Error() })
			return
		}
	}

	var notes []string
	if wantsSupplies(region) && !p.exists(region.ID+".pois.json") {
		p.update(region.ID, func(j *Job) { j.State, j.Step, j.BytesDone = JobRunning, "supplies", j.BytesTotal })
		log.Printf("prepare %s: importing supply locations", region.ID)
		if err := p.builder.BuildPois(ctx, region); err != nil {
			log.Printf("prepare %s: supplies failed: %v", region.ID, err)
			notes = append(notes, "The supply list could not be built: "+err.Error())
		}
	} else if !wantsSupplies(region) {
		notes = append(notes, "Supply lists are only built for cities and provinces.")
	}

	if wantsRoutes(region) && !p.exists(region.ID+".routing.bin") {
		p.update(region.ID, func(j *Job) { j.State, j.Step, j.BytesDone = JobRunning, "routes", j.BytesTotal })
		log.Printf("prepare %s: building the routing network", region.ID)
		if err := p.builder.BuildRoutes(ctx, region); err != nil {
			log.Printf("prepare %s: routes failed: %v", region.ID, err)
			notes = append(notes, "Directions could not be built: "+err.Error())
		}
	} else if !wantsRoutes(region) {
		notes = append(notes, "Offline directions are only built for cities so far.")
	}

	p.update(region.ID, func(j *Job) {
		j.State, j.Step, j.BytesDone, j.Note = JobDone, "", j.BytesTotal, strings.Join(notes, " ")
	})
	log.Printf("prepare %s: done", region.ID)
}

func (p *Preparer) update(id string, change func(*Job)) {
	p.mu.Lock()
	defer p.mu.Unlock()
	change(p.jobs[id])
}

// ToolBuilder runs the repo's Python tools.
type ToolBuilder struct {
	Python   string // interpreter, e.g. "python"
	ToolsDir string // the repo's tool/ directory
	OutDir   string // the regions directory
}

func (b ToolBuilder) BuildMap(ctx context.Context, region CatalogRegion) error {
	return b.run(ctx, "fetch_region.py", region.ID)
}

func (b ToolBuilder) BuildPois(ctx context.Context, region CatalogRegion) error {
	return b.run(ctx, "import_pois.py", region.ID)
}

func (b ToolBuilder) BuildRoutes(ctx context.Context, region CatalogRegion) error {
	return b.run(ctx, "build_routing.py", region.ID)
}

func (b ToolBuilder) run(ctx context.Context, script, id string) error {
	cmd := exec.CommandContext(ctx, b.Python, filepath.Join(b.ToolsDir, script), id, "--out-dir", b.OutDir)
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8")
	out, err := cmd.CombinedOutput()
	if err != nil {
		// The full output goes to the log; the job (which the app shows)
		// gets the last line, which for a Python traceback is the error
		// itself, e.g. "urllib.error.HTTPError: HTTP Error 502: Bad Gateway".
		log.Printf("%s %s output:\n%s", script, id, out)
		return fmt.Errorf("%s", lastLine(string(out), err.Error()))
	}
	return nil
}

func lastLine(text, fallback string) string {
	lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(text, "\r\n", "\n")), "\n")
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
		return last
	}
	return fallback
}
