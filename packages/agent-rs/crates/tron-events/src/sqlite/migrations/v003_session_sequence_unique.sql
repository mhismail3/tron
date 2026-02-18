-- Enforce strict per-session event ordering invariants.
-- A session cannot have two events with the same sequence number.
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique
  ON events(session_id, sequence);
