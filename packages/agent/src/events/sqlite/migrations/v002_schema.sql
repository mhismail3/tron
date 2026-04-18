-- v002: Prompt Library — history and snippets
--
-- Adds two tables:
--   prompt_history  — auto-captured log of every interactive user prompt,
--                     deduplicated by normalized text hash.
--   prompt_snippets — user-authored named quick prompts with CRUD.
--
-- Both are exposed via RPC (promptHistory.*, promptSnippet.*) and browsed
-- from the iOS composer's Prompt Library sheet.

-- ═══════════════════════════════════════════════════════════════════════════════
-- prompt_history
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS prompt_history (
  id             TEXT    PRIMARY KEY,                  -- uuid_v7
  text           TEXT    NOT NULL,                     -- original (trimmed) display text
  text_hash      TEXT    NOT NULL UNIQUE,              -- sha256 hex of normalized text
  first_used_at  TEXT    NOT NULL,                     -- ISO-8601 UTC
  last_used_at   TEXT    NOT NULL,                     -- ISO-8601 UTC
  use_count      INTEGER NOT NULL DEFAULT 1 CHECK(use_count > 0),
  char_count     INTEGER NOT NULL CHECK(char_count > 0)
);

CREATE INDEX IF NOT EXISTS idx_prompt_history_last_used
  ON prompt_history(last_used_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_prompt_history_use_count
  ON prompt_history(use_count DESC);

-- ═══════════════════════════════════════════════════════════════════════════════
-- prompt_snippets
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS prompt_snippets (
  id         TEXT PRIMARY KEY,                         -- uuid_v7
  name       TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 100),
  text       TEXT NOT NULL CHECK(length(text) > 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_prompt_snippets_updated
  ON prompt_snippets(updated_at DESC);
