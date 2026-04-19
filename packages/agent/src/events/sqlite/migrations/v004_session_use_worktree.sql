-- v004: Per-session worktree override.
--
-- Adds a nullable `use_worktree` column to the sessions table so that a
-- session can override the global `session.isolation.mode` setting at
-- create time. The override is consulted once at first-prompt time inside
-- WorktreeCoordinator::maybe_acquire.
--
-- Values:
--   NULL → defer to global isolation mode (existing behavior; default for all
--          pre-migration rows).
--   1    → force-isolate when the dir is a git repo, even if global mode is
--          Never (or Lazy with no other active sessions in the repo).
--   0    → force-passthrough even if global mode is Always.

ALTER TABLE sessions ADD COLUMN use_worktree INTEGER;
