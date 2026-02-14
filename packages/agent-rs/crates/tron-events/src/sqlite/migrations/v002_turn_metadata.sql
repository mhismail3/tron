-- v002: Per-turn metadata columns on events table.
--
-- Adds queryable indexed columns for fields previously buried in JSON payloads.
-- All nullable — existing events are unaffected.

ALTER TABLE events ADD COLUMN model TEXT;
ALTER TABLE events ADD COLUMN latency_ms INTEGER;
ALTER TABLE events ADD COLUMN stop_reason TEXT;
ALTER TABLE events ADD COLUMN has_thinking INTEGER;
ALTER TABLE events ADD COLUMN provider_type TEXT;
ALTER TABLE events ADD COLUMN cost REAL;

-- Indexes for production queries
CREATE INDEX IF NOT EXISTS idx_events_model ON events(session_id, model) WHERE model IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_latency ON events(session_id, latency_ms) WHERE latency_ms IS NOT NULL;
