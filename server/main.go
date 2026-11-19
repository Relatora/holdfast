// Command server is the Holdfast backend: a hazard event relay plus a host
// for region map files.
//
// Configuration (environment variables):
//
//	PORT          listen port (default 8787)
//	REGIONS_DIR   directory with <id>.pmtiles and <id>.pois.json (default ../regions)
//	DATABASE_URL  PostgreSQL+PostGIS connection string; in-memory store when unset
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
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

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           logRequests((&Server{store: store, regionsDir: regionsDir}).Routes()),
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
