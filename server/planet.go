package main

// The current Protomaps planet build.
//
// Protomaps publishes a new planet basemap every day and deletes old daily
// builds within days, so a build URL written into the app stops working
// almost at once. The server reads Protomaps' list of builds instead and
// tells apps the newest one in index.json: apps stream the world map from
// it, and the "Whole world" region downloads from it.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	planetBuildsURL = "https://build-metadata.protomaps.dev/builds.json"
	planetBuildBase = "https://build.protomaps.com/"
)

// PlanetSource knows the newest planet build. It keeps the last answer
// when Protomaps can't be reached, so a blip there never takes the world
// map away.
type PlanetSource struct {
	buildsURL string
	client    *http.Client

	mu  sync.RWMutex
	url string
}

// NewPlanetSource asks for the newest build now and every refresh after
// that, until ctx is cancelled.
func NewPlanetSource(ctx context.Context, buildsURL string, refresh time.Duration) *PlanetSource {
	p := &PlanetSource{buildsURL: buildsURL, client: &http.Client{Timeout: 30 * time.Second}}
	go func() {
		ticker := time.NewTicker(refresh)
		defer ticker.Stop()
		for {
			if err := p.Refresh(ctx); err != nil {
				log.Printf("planet build list: %v (keeping %q)", err, p.URL())
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return p
}

// URL is the newest planet build's URL, or "" before the first answer.
func (p *PlanetSource) URL() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.url
}

// Refresh reads the build list once.
func (p *PlanetSource) Refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.buildsURL, nil)
	if err != nil {
		return err
	}
	// The list rejects Go's default User-Agent; name the software instead.
	req.Header.Set("User-Agent", "holdfast-server")
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var builds []struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&builds); err != nil {
		return err
	}
	// Keys are dated ("20261124.pmtiles") and the list is oldest first.
	newest := ""
	for _, b := range builds {
		if strings.HasSuffix(b.Key, ".pmtiles") && b.Key > newest {
			newest = b.Key
		}
	}
	if newest == "" {
		return fmt.Errorf("no builds listed")
	}
	p.mu.Lock()
	p.url = planetBuildBase + newest
	p.mu.Unlock()
	return nil
}

// maxPlanetRange is the most one proxied request may ask for. A map reads
// a header, directories and tiles: kilobytes to a few megabytes each.
const maxPlanetRange = 16 << 20

// planetProxy serves range requests for the current planet build from this
// server's origin. Browsers need it: Protomaps sends no CORS headers, so
// the web app can't read the build directly. Native apps fetch straight
// from Protomaps and never come here.
//
// Only bounded Range requests are passed on, so the proxy can't be used
// to pull the 140 GB file through this server.
func (s *Server) planetProxy(w http.ResponseWriter, r *http.Request) {
	if s.planet == nil || s.planet.URL() == "" {
		http.NotFound(w, r)
		return
	}
	start, end, ok := parseRange(r.Header.Get("Range"))
	if !ok || end-start+1 > maxPlanetRange {
		httpError(w, http.StatusRequestedRangeNotSatisfiable, "send a Range of at most %d bytes", maxPlanetRange)
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, s.planet.URL(), nil)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "%v", err)
		return
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	req.Header.Set("User-Agent", "holdfast-server")
	resp, err := s.planet.client.Do(req)
	if err != nil {
		httpError(w, http.StatusBadGateway, "planet build: %v", err)
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// parseRange reads "bytes=start-end", the only form PMTiles readers send.
func parseRange(header string) (start, end int64, ok bool) {
	spec, found := strings.CutPrefix(header, "bytes=")
	if !found {
		return 0, 0, false
	}
	from, to, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false
	}
	start, err1 := strconv.ParseInt(from, 10, 64)
	end, err2 := strconv.ParseInt(to, 10, 64)
	if err1 != nil || err2 != nil || start < 0 || end < start {
		return 0, 0, false
	}
	return start, end, true
}
