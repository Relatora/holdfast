// Command server is the Holdfast backend: a hazard event relay plus a host
// for region map files.
//
// Configuration (environment variables):
//
//	PORT          listen port (default 8787)
//	REGIONS_DIR   directory with <id>.pmtiles and <id>.pois.json (default ../regions)
//	DATABASE_URL  PostgreSQL+PostGIS connection string; in-memory store when unset
//
// On-demand region preparation (see prepare.go):
//
//	CATALOG            the app's region catalog (default ../assets/regions/catalog.json)
//	TOOLS_DIR          the repo's tool/ directory (default ../tool)
//	PYTHON             Python interpreter for the tools (default python)
//	PREPARE_MAX_BYTES  largest region built on demand (default 8 GB)
//	REFRESH_DAYS       rebuild hosted regions older than this many days from
//	                   fresh data (default 30; 0 turns automatic refresh off)
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	port := envOr("PORT", "8787")
	regionsDir := envOr("REGIONS_DIR", "../regions")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var store Store
	if url := os.Getenv("DATABASE_URL"); url != "" {
		pg, err := NewPostgresStore(ctx, url)
		if err != nil {
			log.Fatalf("postgres: %v", err)
		}
		defer pg.Close()
		store = pg
		log.Print("using PostgreSQL store")
	} else {
		store = NewMemoryStore()
		log.Print("using in-memory store (set DATABASE_URL for PostgreSQL)")
	}

	server := &Server{store: store, regionsDir: regionsDir}
	catalogPath := envOr("CATALOG", "../assets/regions/catalog.json")
	if catalog, err := LoadCatalog(catalogPath); err != nil {
		log.Printf("on-demand region preparation off: %v", err)
	} else {
		maxBytes, err := strconv.ParseInt(envOr("PREPARE_MAX_BYTES", "8000000000"), 10, 64)
		if err != nil {
			log.Fatalf("PREPARE_MAX_BYTES: %v", err)
		}
		builder := ToolBuilder{
			Python:   envOr("PYTHON", "python"),
			ToolsDir: envOr("TOOLS_DIR", "../tool"),
			OutDir:   regionsDir,
		}
		server.preparer = NewPreparer(ctx, regionsDir, catalog, builder, maxBytes)
		log.Printf("preparing regions up to %d MB on demand", maxBytes/1e6)

		days, err := strconv.Atoi(envOr("REFRESH_DAYS", "30"))
		if err != nil || days < 0 {
			log.Fatalf("REFRESH_DAYS must be a whole number of days, 0 or more")
		}
		if days > 0 {
			go server.preparer.AutoRefresh(ctx, time.Duration(days)*24*time.Hour, time.Hour)
			log.Printf("refreshing hosted regions older than %d days", days)
		}
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           logRequests(server.Routes()),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()

	log.Printf("Holdfast server on http://localhost:%s (regions from %s)", port, regionsDir)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// logRequests logs API calls but not the hundreds of tile range requests a
// single map pan produces.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.Header.Get("Range") == "" {
			log.Printf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
		}
	})
}
