-- v008: Add CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL) to events.
--
-- The invariant: every event must have content somewhere — either inline in
-- `payload` or out-of-line via `content_blob_id`. Today `payload TEXT NOT NULL`
-- covers 100% of the positive case because no code path populates
-- `content_blob_id` yet (every insert passes None, see crud.rs:42). The CHECK
-- is therefore redundant with NOT NULL under the current schema, and exists as
-- defense-in-depth documentation of the intended invariant at the DB level.
--
-- When blob-backed events are introduced (a future migration will relax
-- `payload` to nullable so large bodies can live solely in `blobs`), this
-- CHECK becomes the binding enforcement: the constraint prevents writing an
-- "empty" event that references neither inline content nor a blob.
--
-- SQLite cannot add a table-level CHECK via ALTER TABLE, so this rebuilds
-- `events` around the new constraint. FK enforcement is deferred for the
-- transaction so the DROP+RENAME sequence does not momentarily violate
-- `branches(*_event_id) REFERENCES events(id)` or the self-referential
-- `events(parent_id) REFERENCES events(id)`.
--
-- All indexes (including the UNIQUE(session_id, sequence) constraint that
-- guards the append-only sequence invariant) are recreated verbatim — the
-- rebuild necessarily drops them along with the old table.

PRAGMA defer_foreign_keys = 1;

CREATE TABLE events_new (
  id                   TEXT    PRIMARY KEY,
  session_id           TEXT    NOT NULL REFERENCES sessions(id),
  parent_id            TEXT    REFERENCES events(id),
  sequence             INTEGER NOT NULL,
  depth                INTEGER NOT NULL DEFAULT 0,
  type                 TEXT    NOT NULL,
  timestamp            TEXT    NOT NULL,
  payload              TEXT    NOT NULL,
  content_blob_id      TEXT    REFERENCES blobs(id),
  workspace_id         TEXT    NOT NULL,
  role                 TEXT,
  tool_name            TEXT,
  tool_call_id         TEXT,
  turn                 INTEGER,
  input_tokens         INTEGER,
  output_tokens        INTEGER,
  cache_read_tokens    INTEGER,
  cache_creation_tokens INTEGER,
  checksum             TEXT,
  model                TEXT,
  latency_ms           INTEGER,
  stop_reason          TEXT,
  has_thinking         INTEGER,
  provider_type        TEXT,
  cost                 REAL,
  CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)
);

INSERT INTO events_new
  (id, session_id, parent_id, sequence, depth, type, timestamp, payload,
   content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
   input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
   checksum, model, latency_ms, stop_reason, has_thinking, provider_type, cost)
SELECT
   id, session_id, parent_id, sequence, depth, type, timestamp, payload,
   content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
   input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
   checksum, model, latency_ms, stop_reason, has_thinking, provider_type, cost
FROM events;

DROP TABLE events;
ALTER TABLE events_new RENAME TO events;

-- Recreate indexes dropped with the old table.
CREATE UNIQUE INDEX idx_events_session_sequence_unique ON events(session_id, sequence);
CREATE INDEX idx_events_session_seq ON events(session_id, sequence);
