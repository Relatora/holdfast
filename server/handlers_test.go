package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	ts := httptest.NewServer((&Server{store: NewMemoryStore(), regionsDir: dir}).Routes())
	t.Cleanup(ts.Close)
	return ts, dir
}

const report = `{"id":"e1","kind":"report","hazardId":"h1","deviceId":"a",
  "at":"2026-11-19T12:00:00Z","lat":45.42,"lon":-75.69,"payload":{"type":"flood"}}`
const vote = `{"id":"e2","kind":"vote","hazardId":"h1","deviceId":"b",
  "at":"2026-11-19T12:05:00Z","payload":{"kind":"confirm"}}`

func post(t *testing.T, url, body string) *http.Response {
	t.Helper()
	resp, err := http.Post(url+"/v1/events", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func decode[T any](t *testing.T, resp *http.Response) T {
	t.Helper()
	defer resp.Body.Close()
	var v T
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

type page struct {
	Events []Event `json:"events"`
	Cursor int64   `json:"cursor"`
}

func TestEventsRoundTripAndIdempotency(t *testing.T) {
	ts, _ := newTestServer(t)

	first := decode[map[string]int](t, post(t, ts.URL, `{"events":[`+report+`,`+vote+`]}`))
	if first["added"] != 2 {
		t.Fatalf("added = %d, want 2", first["added"])
	}
	// A retry after a dropped connection must not duplicate anything.
	retry := decode[map[string]int](t, post(t, ts.URL, `{"events":[`+report+`,`+vote+`]}`))
	if retry["added"] != 0 {
		t.Fatalf("retry added = %d, want 0", retry["added"])
	}

	resp, _ := http.Get(ts.URL + "/v1/events?since=0")
	got := decode[page](t, resp)
	if len(got.Events) != 2 || got.Cursor != 2 {
		t.Fatalf("got %d events, cursor %d; want 2, 2", len(got.Events), got.Cursor)
	}

	resp, _ = http.Get(ts.URL + "/v1/events?since=2")
	if after := decode[page](t, resp); len(after.Events) != 0 || after.Cursor != 2 {
		t.Fatalf("after cursor: %d events, cursor %d", len(after.Events), after.Cursor)
	}
}

func TestBBoxIncludesVotesOfHazardsInside(t *testing.T) {
	ts, _ := newTestServer(t)
	post(t, ts.URL, `{"events":[`+report+`,`+vote+`]}`).Body.Close()

	resp, _ := http.Get(ts.URL + "/v1/events?bbox=-76,45,-75,46")
	if inside := decode[page](t, resp); len(inside.Events) != 2 {
		t.Fatalf("inside bbox: %d events, want 2 (report + its vote)", len(inside.Events))
	}
	resp, _ = http.Get(ts.URL + "/v1/events?bbox=0,0,1,1")
	if outside := decode[page](t, resp); len(outside.Events) != 0 {
		t.Fatalf("outside bbox: %d events, want 0", len(outside.Events))
	}
}

func TestRejectsInvalidEvents(t *testing.T) {
	ts, _ := newTestServer(t)
	cases := map[string]string{
		"bad kind":       `{"id":"x","kind":"delete","hazardId":"h","deviceId":"d","at":"2026-11-19T12:00:00Z","payload":{}}`,
		"report no lat":  `{"id":"x","kind":"report","hazardId":"h","deviceId":"d","at":"2026-11-19T12:00:00Z","payload":{}}`,
		"lat range":      `{"id":"x","kind":"report","hazardId":"h","deviceId":"d","at":"2026-11-19T12:00:00Z","lat":91,"lon":0,"payload":{}}`,
		"missing device": `{"id":"x","kind":"vote","hazardId":"h","at":"2026-11-19T12:00:00Z","payload":{}}`,
	}
	for name, event := range cases {
		t.Run(name, func(t *testing.T) {
			resp := post(t, ts.URL, `{"events":[`+event+`]}`)
			resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", resp.StatusCode)
			}
		})
	}
}

func TestRegionFilesSupportRangeRequests(t *testing.T) {
	ts, dir := newTestServer(t)
	content := bytes.Repeat([]byte("0123456789"), 100)
	os.WriteFile(filepath.Join(dir, "ottawa.pmtiles"), content, 0o644)
	os.WriteFile(filepath.Join(dir, "ottawa.pois.json"), []byte(`{"pois":[]}`), 0o644)

	req, _ := http.NewRequest("GET", ts.URL+"/regions/ottawa.pmtiles", nil)
	req.Header.Set("Range", "bytes=10-19")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent || string(body) != "0123456789" {
		t.Fatalf("range: status %d body %q", resp.StatusCode, body)
	}
	if resp.Header.Get("Access-Control-Expose-Headers") == "" {
		t.Fatal("CORS expose headers missing; browsers could not read Content-Range")
	}

	resp, _ = http.Get(ts.URL + "/regions/index.json")
	index := decode[struct {
		Regions map[string]struct {
			PmtilesBytes int64 `json:"pmtilesBytes"`
		} `json:"regions"`
	}](t, resp)
	if index.Regions["ottawa"].PmtilesBytes != 1000 {
		t.Fatalf("index = %v", index)
	}
}

func TestRegionFilesRejectTraversal(t *testing.T) {
	ts, _ := newTestServer(t)
	for _, name := range []string{"..%2Fmain.go", "secret.txt", "OTTAWA.pmtiles"} {
		resp, _ := http.Get(ts.URL + "/regions/" + name)
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: status %d, want 404", name, resp.StatusCode)
		}
	}
}

func TestCredentialsOnlyReachAppsThatAskForThem(t *testing.T) {
	ts, _ := newTestServer(t)
	credential := `{"id":"c1","kind":"credential","hazardId":"credential:a","deviceId":"a",
  "at":"2026-11-20T12:00:00Z","payload":{"type":"training"}}`
	resp := post(t, ts.URL, `{"events":[`+report+`,`+credential+`]}`)
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		t.Fatalf("POST: %d", resp.StatusCode)
	}

	count := func(query string) int {
		resp, err := http.Get(ts.URL + "/v1/events?since=0" + query)
		if err != nil {
			t.Fatal(err)
		}
		return len(decode[struct {
			Events []Event `json:"events"`
		}](t, resp).Events)
	}
	if n := count(""); n != 1 {
		t.Errorf("an old app (no kinds) got %d events, want only the report", n)
	}
	if n := count("&kinds=report,vote,credential"); n != 2 {
		t.Errorf("a new app got %d events, want 2", n)
	}
}
