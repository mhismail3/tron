-- v002: Constitution audit tables for existing v001 databases.
--
-- Fresh databases already get these tables from the consolidated v001 schema.
-- This additive migration is intentionally idempotent so installs that had
-- already recorded v001 still gain the audit ledger without deleting history.

CREATE TABLE IF NOT EXISTS constitution_home_audit (
  id               TEXT PRIMARY KEY,
  occurred_at      TEXT NOT NULL,
  action           TEXT NOT NULL
    CHECK(action IN ('create', 'update', 'move', 'delete', 'migrate', 'seed', 'repair', 'external_edit')),
  home             TEXT NOT NULL,
  path             TEXT NOT NULL,
  old_path         TEXT,
  content_hash     TEXT,
  blob_id          TEXT REFERENCES blobs(id),
  actor            TEXT NOT NULL DEFAULT 'tron',
  reason           TEXT,
  metadata_json    TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_constitution_home_audit_time
  ON constitution_home_audit(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_constitution_home_audit_home_path
  ON constitution_home_audit(home, path);

CREATE TABLE IF NOT EXISTS constitution_resolution_audit (
  id                  TEXT PRIMARY KEY,
  occurred_at         TEXT NOT NULL,
  session_id          TEXT REFERENCES sessions(id),
  turn                INTEGER,
  resolution_type     TEXT NOT NULL
    CHECK(resolution_type IN ('settings', 'instructions', 'context', 'provider_payload', 'vault_access', 'automation_run', 'outcome_feedback')),
  profile             TEXT,
  provider            TEXT,
  model               TEXT,
  effective_hash      TEXT,
  payload_blob_id     TEXT REFERENCES blobs(id),
  metadata_json       TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_constitution_resolution_audit_session_turn
  ON constitution_resolution_audit(session_id, turn);
CREATE INDEX IF NOT EXISTS idx_constitution_resolution_audit_type_time
  ON constitution_resolution_audit(resolution_type, occurred_at DESC);

CREATE TABLE IF NOT EXISTS constitution_context_blocks (
  id                 TEXT PRIMARY KEY,
  resolution_id      TEXT NOT NULL REFERENCES constitution_resolution_audit(id) ON DELETE CASCADE,
  block_id           TEXT NOT NULL,
  name               TEXT NOT NULL,
  source_home        TEXT NOT NULL,
  source_path        TEXT,
  source_blob_id     TEXT REFERENCES blobs(id),
  content_hash       TEXT NOT NULL,
  token_estimate     INTEGER NOT NULL DEFAULT 0,
  sensitivity        TEXT NOT NULL,
  inclusion_reason   TEXT NOT NULL,
  precedence         INTEGER NOT NULL,
  cache_class        TEXT NOT NULL,
  provider_surface   TEXT NOT NULL,
  lifecycle          TEXT NOT NULL,
  included           INTEGER NOT NULL DEFAULT 1 CHECK(included IN (0, 1)),
  metadata_json      TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_constitution_context_blocks_resolution
  ON constitution_context_blocks(resolution_id, precedence);
CREATE INDEX IF NOT EXISTS idx_constitution_context_blocks_hash
  ON constitution_context_blocks(content_hash);
