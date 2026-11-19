-- Append-only hazard event log. Applied on every start; must stay idempotent.
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS events (
    seq         BIGSERIAL PRIMARY KEY,          -- arrival order; the sync cursor
    id          TEXT        NOT NULL UNIQUE,    -- client-generated UUID
    kind        TEXT        NOT NULL CHECK (kind IN ('report', 'vote')),
    hazard_id   TEXT        NOT NULL,
    device_id   TEXT        NOT NULL,
    at          TIMESTAMPTZ NOT NULL,           -- when it happened (client clock)
    location    GEOGRAPHY(Point, 4326),         -- reports only
    payload     JSONB       NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS events_hazard_idx ON events (hazard_id);
CREATE INDEX IF NOT EXISTS events_location_idx ON events USING GIST (location);
