-- v007: Widen device_tokens identity from (device_token, platform) to
-- (device_token, platform, workspace_id, bundle_id).
--
-- The legacy narrow UNIQUE prevented the SAME APNs push token from being
-- registered against two different workspaces on the same device, or against
-- two different APNs `apns-topic` bundles (com.tron.mobile vs
-- com.tron.mobile.beta after the Xcode scheme split introduced in v006).
-- A second register() against the same token would clobber the first row,
-- so the earlier workspace silently stopped receiving pushes.
--
-- SQLite cannot drop a table-level UNIQUE constraint with ALTER TABLE, so
-- this rebuilds `device_tokens` around a wider identity. Every row the old
-- schema accepted (distinct (device_token, platform)) is still accepted by
-- the new schema (the new identity is a superset), so the copy cannot fail
-- on existing data.
--
-- NULL handling is critical: SQLite's native UNIQUE treats every NULL as
-- distinct, which would allow unbounded duplicate `(token, ios, NULL, NULL)`
-- rows and defeat dedup for legacy pre-v006/pre-M3 registrations that still
-- carry NULL workspace_id or NULL bundle_id. We use a CREATE UNIQUE INDEX
-- with COALESCE(col, '') on both nullable columns so NULLs collapse to a
-- single canonical key. Empty strings cannot be workspace or bundle IDs
-- in practice (workspace IDs are UUIDs; bundle IDs are reverse-DNS), so
-- the sentinel is unambiguous.
--
-- Auxiliary indexes (session, workspace, token) are recreated verbatim —
-- the rebuild necessarily drops them along with the old table, and callers
-- rely on them for active-row filters and token lookups.

CREATE TABLE device_tokens_new (
  id           TEXT PRIMARY KEY,
  device_token TEXT NOT NULL,
  session_id   TEXT REFERENCES sessions(id),
  workspace_id TEXT REFERENCES workspaces(id),
  platform     TEXT NOT NULL DEFAULT 'ios',
  environment  TEXT NOT NULL DEFAULT 'production',
  bundle_id    TEXT,
  created_at   TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  is_active    INTEGER NOT NULL DEFAULT 1
);

INSERT INTO device_tokens_new
  (id, device_token, session_id, workspace_id, platform, environment,
   bundle_id, created_at, last_used_at, is_active)
SELECT
  id, device_token, session_id, workspace_id, platform, environment,
  bundle_id, created_at, last_used_at, is_active
FROM device_tokens;

DROP TABLE device_tokens;
ALTER TABLE device_tokens_new RENAME TO device_tokens;

-- Identity index: (device_token, platform, COALESCE(workspace_id, ''),
-- COALESCE(bundle_id, '')). COALESCE collapses NULL to '' so two rows with
-- NULL workspace+bundle are rejected as duplicates rather than admitted
-- as distinct-by-NULL (SQLite's default).
CREATE UNIQUE INDEX idx_device_tokens_identity
  ON device_tokens (
    device_token,
    platform,
    COALESCE(workspace_id, ''),
    COALESCE(bundle_id, '')
  );

-- Recreate the auxiliary indexes dropped with the old table.
CREATE INDEX idx_device_tokens_session   ON device_tokens(session_id)   WHERE is_active = 1;
CREATE INDEX idx_device_tokens_workspace ON device_tokens(workspace_id) WHERE is_active = 1;
CREATE INDEX idx_device_tokens_token     ON device_tokens(device_token);
