-- v002: Add source column to sessions table.
--
-- Tracks how a session was created (e.g. 'cron' for scheduled runs).
-- User-created sessions have source = NULL.

ALTER TABLE sessions ADD COLUMN source TEXT;

-- Backfill existing cron sessions based on title prefix.
UPDATE sessions SET source = 'cron' WHERE title LIKE 'Cron: %';

-- Index for filtering by source.
CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
