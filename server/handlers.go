package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	maxBatch   = 500     // events per POST
	maxPayload = 4 << 10 // bytes per event payload
	maxBody    = 2 << 20 // bytes per request
	pageSize   = 1000    // events per GET
)

// Server holds the HTTP handlers' dependencies.
type Server struct {
	store      Store
	regionsDir string
	// preparer builds missing regions on demand; nil turns that off (for
	// example when the catalog file can't be found).
	preparer *Preparer
	// planet names the newest Protomaps planet build; nil leaves it out of
	// index.json (apps then use the catalog's URL).
	planet *PlanetSource
}

// Routes wires every endpoint, wrapped in CORS so the web build can call
// the API and stream map tiles from another origin.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /v1/events", s.postEvents)
	mux.HandleFunc("GET /v1/events", s.getEvents)
	mux.HandleFunc("GET /regions/index.json", s.regionIndex)
	// Registered before /regions/{file}, and more specific, so it wins.
	mux.HandleFunc("GET /regions/planet.pmtiles", s.planetProxy)
	mux.HandleFunc("GET /regions/{file}", s.regionFile)
	mux.HandleFunc("POST /regions/{id}/prepare", s.startPrepare)
	mux.HandleFunc("GET /regions/{id}/prepare", s.prepareStatus)
	mux.HandleFunc("POST /regions/{id}/refresh", s.startRefresh)
	return withCORS(mux)
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", "*")
		h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		// Range is how PMTiles readers fetch individual tiles from one file.
		h.Set("Access-Control-Allow-Headers", "Content-Type, Range")
		h.Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges, ETag")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- Events ------------------------------------------------------------------

func (s *Server) postEvents(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Events []Event `json:"events"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}
	if len(body.Events) > maxBatch {
		httpError(w, http.StatusRequestEntityTooLarge, "at most %d events per request", maxBatch)
		return
	}
	for i, e := range body.Events {
		if err := validate(e); err != nil {
			httpError(w, http.StatusBadRequest, "event %d: %v", i, err)
			return
		}
	}
	added, err := s.store.Append(r.Context(), body.Events)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "store: %v", err)
		return
	}
	writeJSON(w, map[string]int{"received": len(body.Events), "added": added})
}

var errInvalid = errors.New("invalid event")

func validate(e Event) error {
	switch {
	case e.ID == "" || len(e.ID) > 64:
		return fmt.Errorf("%w: id must be 1-64 characters", errInvalid)
	case e.Kind != "report" && e.Kind != "vote" && e.Kind != "credential":
		return fmt.Errorf("%w: kind must be report, vote or credential", errInvalid)
	case e.HazardID == "" || e.DeviceID == "":
		return fmt.Errorf("%w: hazardId and deviceId are required", errInvalid)
	case e.At.IsZero():
		return fmt.Errorf("%w: at is required", errInvalid)
	case len(e.Payload) == 0 || len(e.Payload) > maxPayload:
		return fmt.Errorf("%w: payload must be 1-%d bytes", errInvalid, maxPayload)
	case e.Kind == "report" && (e.Lat == nil || e.Lon == nil):
		return fmt.Errorf("%w: reports need lat and lon", errInvalid)
	case e.Lat != nil && (*e.Lat < -90 || *e.Lat > 90):
		return fmt.Errorf("%w: lat out of range", errInvalid)
	case e.Lon != nil && (*e.Lon < -180 || *e.Lon > 180):
		return fmt.Errorf("%w: lon out of range", errInvalid)
	}
	return nil
}

func (s *Server) getEvents(w http.ResponseWriter, r *http.Request) {
	cursor, err := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if err != nil && r.URL.Query().Has("since") {
		httpError(w, http.StatusBadRequest, "since must be an integer")
		return
	}
	var bbox *BBox
	if raw := r.URL.Query().Get("bbox"); raw != "" {
		b, err := parseBBox(raw)
		if err != nil {
			httpError(w, http.StatusBadRequest, "%v", err)
			return
		}
		bbox = &b
	}
	events, next, err := s.store.Since(r.Context(), cursor, bbox, pageSize)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "store: %v", err)
		return
	}
	// Apps list the event kinds they can read. Apps from before that
	// parameter existed (0.1-0.3) crash on a kind they don't know, so they
	// only ever get reports and votes. The cursor still advances past
	// anything filtered out.
	kinds := map[string]bool{"report": true, "vote": true}
	if raw := r.URL.Query().Get("kinds"); raw != "" {
		kinds = map[string]bool{}
		for _, k := range strings.Split(raw, ",") {
			kinds[k] = true
		}
	}
	readable := events[:0:0]
	for _, e := range events {
		if kinds[e.Kind] {
			readable = append(readable, e)
		}
	}
	writeJSON(w, map[string]any{"events": readable, "cursor": next})
}

func parseBBox(raw string) (BBox, error) {
	parts := strings.Split(raw, ",")
	if len(parts) != 4 {
		return BBox{}, errors.New("bbox must be west,south,east,north")
	}
	var v [4]float64
	for i, p := range parts {
		f, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return BBox{}, fmt.Errorf("bbox value %q is not a number", p)
		}
		v[i] = f
	}
	return BBox{West: v[0], South: v[1], East: v[2], North: v[3]}, nil
}

// ---- Regions -----------------------------------------------------------------

// Only plain region file names are served, which rules out path traversal
// ("../../etc/passwd") without having to reason about cleaned paths.
var regionFileName = regexp.MustCompile(`^[a-z0-9-]+\.(pmtiles|pois\.json|routing\.bin|population\.bin|cells\.bin)$`)

// regionIndex lists the region files actually present, with real sizes, so
// the app can show which catalog regions are downloadable and how big.
func (s *Server) regionIndex(w http.ResponseWriter, _ *http.Request) {
	type entry struct {
		PmtilesBytes    int64  `json:"pmtilesBytes"`
		PoisBytes       *int64 `json:"poisBytes,omitempty"`
		RoutingBytes    *int64 `json:"routingBytes,omitempty"`
		PopulationBytes *int64 `json:"populationBytes,omitempty"`
		CellsBytes      *int64 `json:"cellsBytes,omitempty"`
		// BuiltAt is when the region's files last changed; an app whose
		// copy is older offers an update.
		BuiltAt time.Time `json:"builtAt"`
	}
	regions := map[string]entry{}
	matches, _ := filepath.Glob(filepath.Join(s.regionsDir, "*.pmtiles"))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		id := strings.TrimSuffix(filepath.Base(path), ".pmtiles")
		e := entry{PmtilesBytes: info.Size(), BuiltAt: BuiltAt(s.regionsDir, id).UTC().Truncate(time.Second)}
		if pois, err := os.Stat(filepath.Join(s.regionsDir, id+".pois.json")); err == nil {
			size := pois.Size()
			e.PoisBytes = &size
		}
		if routing, err := os.Stat(filepath.Join(s.regionsDir, id+".routing.bin")); err == nil {
			size := routing.Size()
			e.RoutingBytes = &size
		}
		if population, err := os.Stat(filepath.Join(s.regionsDir, id+".population.bin")); err == nil {
			size := population.Size()
			e.PopulationBytes = &size
		}
		if cells, err := os.Stat(filepath.Join(s.regionsDir, id+".cells.bin")); err == nil {
			size := cells.Size()
			e.CellsBytes = &size
		}
		regions[id] = e
	}
	// "prepare" tells the app which missing regions it can still offer:
	// anything up to maxBytes. "jobs" lets it resume showing progress for
	// work started before it was restarted.
	prepare := map[string]any{"enabled": false}
	jobs := map[string]Job{}
	if s.preparer != nil {
		prepare = map[string]any{"enabled": true, "maxBytes": s.preparer.MaxBytes()}
		jobs = s.preparer.Active()
	}
	body := map[string]any{"regions": regions, "prepare": prepare, "jobs": jobs}
	if s.planet != nil && s.planet.URL() != "" {
		body["planet"] = s.planet.URL()
	}
	writeJSON(w, body)
}

var regionID = regexp.MustCompile(`^[a-z0-9-]+$`)

// startPrepare queues a region build. 202 with the job; repeated calls
// return the same job, so the app can simply call it again after a restart.
func (s *Server) startPrepare(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.preparer == nil || !regionID.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	job, err := s.preparer.Start(id)
	switch {
	case errors.Is(err, errUnknownRegion):
		httpError(w, http.StatusNotFound, "unknown region %q", id)
	case errors.Is(err, errTooBig):
		httpError(w, http.StatusRequestEntityTooLarge,
			"%s is larger than this server prepares on demand (%d MB)", id, s.preparer.MaxBytes()/1e6)
	case errors.Is(err, errStreamed):
		httpError(w, http.StatusConflict, "%s streams from its own source", id)
	case err != nil:
		httpError(w, http.StatusInternalServerError, "%v", err)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(job)
	}
}

// startRefresh queues a rebuild of a hosted region from fresh data: 202 with
// the job, which GET /regions/{id}/prepare then follows. It's an operator's
// tool (the server also refreshes old regions by itself, see AutoRefresh);
// apps only notice the result, through builtAt in index.json.
func (s *Server) startRefresh(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.preparer == nil || !regionID.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	job, err := s.preparer.Refresh(id)
	switch {
	case errors.Is(err, errUnknownRegion), errors.Is(err, errNotHosted):
		httpError(w, http.StatusNotFound, "%s: %v", id, err)
	case errors.Is(err, errTooBig):
		httpError(w, http.StatusRequestEntityTooLarge,
			"%s is larger than this server builds (%d MB)", id, s.preparer.MaxBytes()/1e6)
	case errors.Is(err, errStreamed):
		httpError(w, http.StatusConflict, "%s streams from its own source", id)
	case err != nil:
		httpError(w, http.StatusInternalServerError, "%v", err)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(job)
	}
}

func (s *Server) prepareStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.preparer == nil || !regionID.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	job, ok := s.preparer.Status(id)
	if !ok {
		httpError(w, http.StatusNotFound, "no preparation job for %q", id)
		return
	}
	writeJSON(w, job)
}

// regionFile serves one region file. http.ServeContent implements Range,
// If-Range and ETag handling, which PMTiles streaming and resumable
// downloads both depend on.
func (s *Server) regionFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("file")
	if !regionFileName.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(filepath.Join(s.regionsDir, name))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "stat: %v", err)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=3600")
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// ---- Helpers -----------------------------------------------------------------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, status int, format string, args ...any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": fmt.Sprintf(format, args...)})
}
