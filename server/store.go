package main

import (
	"context"
	"encoding/json"
	"sync"
	"time"
)

// Event is one fact about a hazard: a report or a vote. The server treats
// the payload as opaque; deciding what is "verified" is the clients' job,
// so every device (including mesh peers that never see this server) applies
// identical rules to identical facts.
type Event struct {
	ID       string          `json:"id"`
	Kind     string          `json:"kind"` // "report" or "vote"
	HazardID string          `json:"hazardId"`
	DeviceID string          `json:"deviceId"`
	At       time.Time       `json:"at"`
	Lat      *float64        `json:"lat,omitempty"`
	Lon      *float64        `json:"lon,omitempty"`
	Payload  json.RawMessage `json:"payload"`
}

// BBox is a west/south/east/north box in degrees.
type BBox struct{ West, South, East, North float64 }

func (b BBox) contains(lat, lon float64) bool {
	return lat >= b.South && lat <= b.North && lon >= b.West && lon <= b.East
}

// Store persists events in arrival order. Each stored event gets a
// monotonically increasing sequence number; clients page through the log
// with "give me everything after sequence N".
type Store interface {
	// Append stores events whose IDs are new and returns how many were new.
	// Re-sending an event is harmless, so clients can retry freely.
	Append(ctx context.Context, events []Event) (int, error)

	// Since returns up to limit events with sequence > cursor, and the
	// cursor to resume from. With a bbox, only events for hazards reported
	// inside it are returned (votes carry no location of their own).
	Since(ctx context.Context, cursor int64, bbox *BBox, limit int) ([]Event, int64, error)
}

// MemoryStore keeps everything in RAM. It's the default for development and
// the reference implementation the HTTP tests run against.
type MemoryStore struct {
	mu        sync.RWMutex
	events    []Event               // index i holds sequence i+1
	ids       map[string]bool       // for idempotent appends
	locations map[string][2]float64 // hazardId -> lat, lon of its report
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{ids: map[string]bool{}, locations: map[string][2]float64{}}
}

func (m *MemoryStore) Append(_ context.Context, events []Event) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	added := 0
	for _, e := range events {
		if m.ids[e.ID] {
			continue
		}
		m.ids[e.ID] = true
		m.events = append(m.events, e)
		if e.Kind == "report" && e.Lat != nil && e.Lon != nil {
			m.locations[e.HazardID] = [2]float64{*e.Lat, *e.Lon}
		}
		added++
	}
	return added, nil
}

func (m *MemoryStore) Since(_ context.Context, cursor int64, bbox *BBox, limit int) ([]Event, int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := []Event{}
	next := cursor
	for seq := cursor + 1; seq <= int64(len(m.events)) && len(out) < limit; seq++ {
		e := m.events[seq-1]
		next = seq
		if bbox != nil {
			loc, ok := m.locations[e.HazardID]
			if !ok || !bbox.contains(loc[0], loc[1]) {
				continue
			}
		}
		out = append(out, e)
	}
	return out, next, nil
}
