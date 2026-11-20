package main

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Migrations, applied in order on every start; each must be idempotent.
//
//go:embed migrations/001_events.sql
var schemaSQL string

//go:embed migrations/002_credential_kind.sql
var credentialKindSQL string

// PostgresStore is the production store: PostgreSQL with PostGIS, so
// "events for hazards in this map area" is an indexed spatial query rather
// than a scan.
type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore connects and applies the schema (idempotent).
func NewPostgresStore(ctx context.Context, url string) (*PostgresStore, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	for _, migration := range []string{schemaSQL, credentialKindSQL} {
		if _, err := pool.Exec(ctx, migration); err != nil {
			pool.Close()
			return nil, fmt.Errorf("migrate: %w", err)
		}
	}
	return &PostgresStore{pool: pool}, nil
}

func (p *PostgresStore) Close() { p.pool.Close() }

func (p *PostgresStore) Append(ctx context.Context, events []Event) (int, error) {
	batch := &pgx.Batch{}
	for _, e := range events {
		// ON CONFLICT makes retries harmless: an id is stored at most once.
		batch.Queue(`
			INSERT INTO events (id, kind, hazard_id, device_id, at, location, payload)
			VALUES ($1, $2, $3, $4, $5,
			        CASE WHEN $6::float8 IS NULL THEN NULL
			             ELSE ST_SetSRID(ST_MakePoint($7, $6), 4326)::geography END,
			        $8)
			ON CONFLICT (id) DO NOTHING`,
			e.ID, e.Kind, e.HazardID, e.DeviceID, e.At, e.Lat, e.Lon, []byte(e.Payload))
	}
	results := p.pool.SendBatch(ctx, batch)
	defer results.Close()
	added := 0
	for range events {
		tag, err := results.Exec()
		if err != nil {
			return added, err
		}
		added += int(tag.RowsAffected())
	}
	return added, nil
}

func (p *PostgresStore) Since(ctx context.Context, cursor int64, bbox *BBox, limit int) ([]Event, int64, error) {
	query := `
		SELECT seq, id, kind, hazard_id, device_id, at,
		       ST_Y(location::geometry), ST_X(location::geometry), payload
		FROM events
		WHERE seq > $1`
	args := []any{cursor}
	if bbox != nil {
		// Votes have no location; include them when their hazard's report
		// falls inside the box.
		query += `
		  AND hazard_id IN (
		      SELECT hazard_id FROM events
		      WHERE kind = 'report'
		        AND ST_Intersects(location, ST_MakeEnvelope($2, $3, $4, $5, 4326)::geography))`
		args = append(args, bbox.West, bbox.South, bbox.East, bbox.North)
	}
	query += fmt.Sprintf(" ORDER BY seq LIMIT %d", limit)

	rows, err := p.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, cursor, err
	}
	defer rows.Close()

	out := []Event{}
	next := cursor
	for rows.Next() {
		var e Event
		var seq int64
		var payload []byte
		if err := rows.Scan(&seq, &e.ID, &e.Kind, &e.HazardID, &e.DeviceID, &e.At, &e.Lat, &e.Lon, &payload); err != nil {
			return nil, cursor, err
		}
		e.Payload = payload
		out = append(out, e)
		next = seq
	}
	return out, next, rows.Err()
}
