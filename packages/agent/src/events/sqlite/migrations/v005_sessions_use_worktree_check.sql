-- v005: Enforce use_worktree IN (0, 1, NULL) on sessions.
--
-- v004 added `use_worktree INTEGER` (nullable) but no enforcement, so a
-- stray integer (e.g. 2 from a buggy writer) would silently coerce to
-- `true` via rusqlite's INTEGER → bool mapping. SQLite cannot ADD
-- CONSTRAINT to an existing column, and the standard 12-step rebuild
-- runs into foreign-key reference rewriting issues against existing
-- referencers (events, branches). Triggers achieve the same invariant
-- without disturbing the schema or any FK relationships.

DROP TRIGGER IF EXISTS trg_sessions_use_worktree_insert;
DROP TRIGGER IF EXISTS trg_sessions_use_worktree_update;

CREATE TRIGGER trg_sessions_use_worktree_insert
BEFORE INSERT ON sessions
WHEN NEW.use_worktree IS NOT NULL AND NEW.use_worktree NOT IN (0, 1)
BEGIN
  SELECT RAISE(ABORT, 'use_worktree must be 0, 1, or NULL');
END;

CREATE TRIGGER trg_sessions_use_worktree_update
BEFORE UPDATE OF use_worktree ON sessions
WHEN NEW.use_worktree IS NOT NULL AND NEW.use_worktree NOT IN (0, 1)
BEGIN
  SELECT RAISE(ABORT, 'use_worktree must be 0, 1, or NULL');
END;
