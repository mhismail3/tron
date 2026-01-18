/**
 * @fileoverview Migration System Exports
 *
 * Provides the migration runner and all registered migrations.
 */

import type Database from 'better-sqlite3';
import { MigrationRunner, createMigrationRunner } from './runner.js';
import type { Migration, MigrationResult } from './types.js';

// Import migrations
import { migration as v001Initial } from './versions/v001-initial.js';

/**
 * All registered migrations in order
 */
export const migrations: Migration[] = [
  v001Initial,
];

/**
 * Run all pending migrations on the database
 */
export function runMigrations(db: Database.Database): MigrationResult {
  const runner = createMigrationRunner(db, migrations);
  return runner.run();
}

/**
 * Run incremental migrations for existing databases
 *
 * These handle schema changes for databases created before certain versions.
 * New databases get the full schema from v001 and don't need these.
 */
export function runIncrementalMigrations(db: Database.Database): void {
  const runner = new MigrationRunner(db, []);

  // Check if sessions table exists
  if (!runner.tableExists('sessions')) {
    return;
  }

  // Migration: Add total_cost column (added in a patch)
  runner.addColumnIfNotExists('sessions', 'total_cost', 'REAL DEFAULT 0');

  // Migration: Add last_turn_input_tokens for context size tracking
  runner.addColumnIfNotExists('sessions', 'last_turn_input_tokens', 'INTEGER DEFAULT 0');

  // Migration: Add cache token columns for prompt caching
  runner.addColumnIfNotExists('sessions', 'total_cache_read_tokens', 'INTEGER DEFAULT 0');
  runner.addColumnIfNotExists('sessions', 'total_cache_creation_tokens', 'INTEGER DEFAULT 0');

  // Migration: Schema cleanup (remove provider/status, rename model)
  // This is a major migration that rebuilds the sessions table
  runProviderStatusMigration(db, runner);

  // Migration: Add subagent tracking columns
  runner.addColumnIfNotExists('sessions', 'spawning_session_id', 'TEXT');
  runner.addColumnIfNotExists('sessions', 'spawn_type', 'TEXT');
  runner.addColumnIfNotExists('sessions', 'spawn_task', 'TEXT');

  // Create index for querying subagents by parent session
  const indices = db.prepare("SELECT name FROM sqlite_master WHERE type='index'").all() as { name: string }[];
  const hasIndex = indices.some(i => i.name === 'idx_sessions_spawning');
  if (!hasIndex) {
    db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_spawning ON sessions(spawning_session_id, ended_at)');
  }
}

/**
 * Remove provider/status columns and rename model to latest_model
 *
 * This migration is only needed for databases created before v2.
 * It uses table rebuild since SQLite doesn't support DROP COLUMN.
 */
function runProviderStatusMigration(db: Database.Database, runner: MigrationRunner): void {
  const columns = runner.getTableColumns('sessions');

  // Check if migration is needed (provider column exists = old schema)
  if (!columns.includes('provider')) {
    return;
  }

  // Disable foreign keys during rebuild
  db.pragma('foreign_keys = OFF');

  db.exec(`
    -- Clean up any partial migration state
    DROP TABLE IF EXISTS sessions_new;

    -- Create new sessions table without provider/status, with latest_model
    CREATE TABLE sessions_new (
      id TEXT PRIMARY KEY,
      workspace_id TEXT NOT NULL REFERENCES workspaces(id),
      head_event_id TEXT,
      root_event_id TEXT,
      title TEXT,
      latest_model TEXT NOT NULL,
      working_directory TEXT NOT NULL,
      parent_session_id TEXT REFERENCES sessions(id),
      fork_from_event_id TEXT,
      created_at TEXT NOT NULL,
      last_activity_at TEXT NOT NULL,
      ended_at TEXT,
      event_count INTEGER DEFAULT 0,
      message_count INTEGER DEFAULT 0,
      turn_count INTEGER DEFAULT 0,
      total_input_tokens INTEGER DEFAULT 0,
      total_output_tokens INTEGER DEFAULT 0,
      total_cost REAL DEFAULT 0,
      last_turn_input_tokens INTEGER DEFAULT 0,
      total_cache_read_tokens INTEGER DEFAULT 0,
      total_cache_creation_tokens INTEGER DEFAULT 0,
      tags TEXT DEFAULT '[]'
    );

    -- Copy data from old table (model -> latest_model, status -> ended_at)
    INSERT INTO sessions_new
    SELECT
      id, workspace_id, head_event_id, root_event_id, title,
      model, working_directory, parent_session_id, fork_from_event_id,
      created_at, last_activity_at,
      CASE WHEN status = 'ended' THEN last_activity_at ELSE NULL END,
      event_count, message_count,
      turn_count, total_input_tokens, total_output_tokens,
      COALESCE(total_cost, 0),
      COALESCE(last_turn_input_tokens, 0),
      COALESCE(total_cache_read_tokens, 0),
      COALESCE(total_cache_creation_tokens, 0),
      tags
    FROM sessions;

    -- Drop old table and rename new one
    DROP TABLE sessions;
    ALTER TABLE sessions_new RENAME TO sessions;

    -- Recreate indexes
    CREATE INDEX idx_sessions_workspace ON sessions(workspace_id);
    CREATE INDEX idx_sessions_activity ON sessions(last_activity_at DESC);
    CREATE INDEX idx_sessions_parent ON sessions(parent_session_id);
    CREATE INDEX idx_sessions_working_dir ON sessions(working_directory);
    CREATE INDEX idx_sessions_ended ON sessions(ended_at);

    -- Update schema version
    INSERT OR REPLACE INTO schema_version (version, applied_at, description)
    VALUES (2, datetime('now'), 'Remove provider/status columns, rename model to latest_model');
  `);

  // Re-enable foreign keys
  db.pragma('foreign_keys = ON');
}

// Re-export types and runner
export type { Migration, MigrationResult, SchemaVersionRow, ColumnInfo } from './types.js';
export { MigrationRunner, createMigrationRunner } from './runner.js';
