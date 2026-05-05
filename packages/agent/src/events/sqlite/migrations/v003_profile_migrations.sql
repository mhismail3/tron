-- v003: Profile migration ledger.
--
-- Records profile schema/layout migrations separately from SQLite schema
-- migrations so live verification can prove whether temporary profile migrators
-- are still being used.

CREATE TABLE IF NOT EXISTS profile_migrations (
  id                    TEXT PRIMARY KEY,
  occurred_at           TEXT NOT NULL DEFAULT (datetime('now')),
  source_version        TEXT NOT NULL,
  target_version        TEXT NOT NULL,
  profile_name          TEXT,
  source_hash           TEXT,
  result                TEXT NOT NULL CHECK(result IN ('applied', 'skipped', 'failed')),
  legacy_input_observed INTEGER NOT NULL DEFAULT 0 CHECK(legacy_input_observed IN (0, 1)),
  details_json          TEXT
);

CREATE INDEX IF NOT EXISTS idx_profile_migrations_time
  ON profile_migrations(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_profile_migrations_legacy
  ON profile_migrations(legacy_input_observed, occurred_at DESC);
