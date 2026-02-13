/**
 * @fileoverview Migration System Exports
 *
 * Provides the migration runner and all registered migrations.
 */

import type { Database } from 'bun:sqlite';
import { MigrationRunner, createMigrationRunner } from './runner.js';
import type { Migration, MigrationResult } from './types.js';

// Import migrations
import { migration as v001Initial } from './versions/v001-initial.js';
import { migration as v002Backlog } from './versions/v002-backlog.js';
import { migration as v003DeviceTokens } from './versions/v003-device-tokens.js';
import { migration as v004Indexes } from './versions/v004-indexes.js';
import { migration as v005TraceColumns } from './versions/v005-trace-columns.js';
import { migration as v006MemoryVectors } from './versions/v006-memory-vectors.js';
import { migration as v007Tasks } from './versions/v007-tasks.js';
import { migration as v008Areas } from './versions/v008-areas.js';
import { migration as v009ArchiveRename } from './versions/v009-archive-rename.js';

/**
 * All registered migrations in order
 */
export const migrations: Migration[] = [
  v001Initial,
  v002Backlog,
  v003DeviceTokens,
  v004Indexes,
  v005TraceColumns,
  v006MemoryVectors,
  v007Tasks,
  v008Areas,
  v009ArchiveRename,
];

/**
 * Run all pending migrations on the database
 */
export function runMigrations(db: Database): MigrationResult {
  const runner = createMigrationRunner(db, migrations);
  return runner.run();
}

/**
 * Run incremental migrations for existing databases
 *
 * These handle schema changes for databases created before certain versions.
 * New databases get the full schema from v001 and don't need these.
 */
export function runIncrementalMigrations(db: Database): void {
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
    db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_spawning ON sessions(spawning_session_id, archived_at)');
  }

  // Migration: Update FTS trigger to extract memory.ledger fields
  // The original trigger only extracts $.content, which is empty for memory.ledger events.
  // Replace it with one that concatenates structured fields for memory.ledger.
  runFtsTriggerMigration(db);
}

/**
 * Update the events_fts_insert trigger to handle memory.ledger events.
 *
 * memory.ledger events store searchable data in title, input, actions, lessons,
 * decisions, and files fields — not in content. The old trigger produced empty
 * FTS content for these events.
 */
function runFtsTriggerMigration(db: Database): void {
  // Check if trigger needs updating by looking for the memory.ledger-aware version
  const triggers = db.prepare(
    "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='events_fts_insert'"
  ).get() as { sql: string } | undefined;

  if (!triggers?.sql || triggers.sql.includes('memory.ledger')) {
    // Already updated or trigger doesn't exist
    return;
  }

  // Drop and recreate with memory.ledger support
  db.exec(`
    DROP TRIGGER IF EXISTS events_fts_insert;

    CREATE TRIGGER events_fts_insert
    AFTER INSERT ON events
    BEGIN
      INSERT INTO events_fts (id, session_id, type, content, tool_name)
      VALUES (
        NEW.id,
        NEW.session_id,
        NEW.type,
        CASE
          WHEN NEW.type = 'memory.ledger' AND json_valid(NEW.payload) THEN
            COALESCE(json_extract(NEW.payload, '$.title'), '') || ' ' ||
            COALESCE(json_extract(NEW.payload, '$.input'), '') || ' ' ||
            COALESCE(json_extract(NEW.payload, '$.entryType'), '') || ' ' ||
            COALESCE(json_extract(NEW.payload, '$.status'), '')
          WHEN json_valid(NEW.payload) THEN
            COALESCE(json_extract(NEW.payload, '$.content'), '')
          ELSE ''
        END,
        COALESCE(
          NEW.tool_name,
          CASE WHEN json_valid(NEW.payload)
            THEN COALESCE(
              json_extract(NEW.payload, '$.toolName'),
              json_extract(NEW.payload, '$.name')
            )
            ELSE NULL
          END,
          ''
        )
      );
    END;
  `);

  // Re-index existing memory.ledger events
  // Delete old (empty) FTS entries and re-insert with proper content
  const memoryEvents = db.prepare(`
    SELECT id, session_id, type, payload
    FROM events
    WHERE type = 'memory.ledger'
  `).all() as Array<{ id: string; session_id: string; type: string; payload: string }>;

  if (memoryEvents.length > 0) {
    db.exec('DELETE FROM events_fts WHERE type = \'memory.ledger\'');

    const insert = db.prepare(`
      INSERT INTO events_fts (id, session_id, type, content, tool_name)
      VALUES (?, ?, ?, ?, '')
    `);

    for (const evt of memoryEvents) {
      let content = '';
      try {
        const p = JSON.parse(evt.payload);
        const parts: string[] = [];
        if (typeof p.title === 'string') parts.push(p.title);
        if (typeof p.input === 'string') parts.push(p.input);
        if (typeof p.entryType === 'string') parts.push(p.entryType);
        if (typeof p.status === 'string') parts.push(p.status);
        if (Array.isArray(p.actions)) parts.push(...p.actions.filter((a: unknown) => typeof a === 'string'));
        if (Array.isArray(p.lessons)) parts.push(...p.lessons.filter((l: unknown) => typeof l === 'string'));
        if (Array.isArray(p.decisions)) {
          for (const d of p.decisions) {
            if (d && typeof d === 'object') {
              if (typeof d.choice === 'string') parts.push(d.choice);
              if (typeof d.reason === 'string') parts.push(d.reason);
            }
          }
        }
        if (Array.isArray(p.files)) {
          for (const f of p.files) {
            if (f && typeof f === 'object') {
              if (typeof f.path === 'string') parts.push(f.path);
              if (typeof f.why === 'string') parts.push(f.why);
            }
          }
        }
        if (Array.isArray(p.tags)) parts.push(...p.tags.filter((t: unknown) => typeof t === 'string'));
        content = parts.join(' ');
      } catch { /* skip malformed */ }

      insert.run(evt.id, evt.session_id, evt.type, content);
    }
  }
}

/**
 * Remove provider/status columns and rename model to latest_model
 *
 * This migration is only needed for databases created before v2.
 * It uses table rebuild since SQLite doesn't support DROP COLUMN.
 */
function runProviderStatusMigration(db: Database, runner: MigrationRunner): void {
  const columns = runner.getTableColumns('sessions');

  // Check if migration is needed (provider column exists = old schema)
  if (!columns.includes('provider')) {
    return;
  }

  // Disable foreign keys during rebuild
  db.run('PRAGMA foreign_keys = OFF');

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
      archived_at TEXT,
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

    -- Copy data from old table (model -> latest_model, status -> archived_at)
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
    CREATE INDEX idx_sessions_archived ON sessions(archived_at);

    -- Update schema version
    INSERT OR REPLACE INTO schema_version (version, applied_at, description)
    VALUES (2, datetime('now'), 'Remove provider/status columns, rename model to latest_model');
  `);

  // Re-enable foreign keys
  db.run('PRAGMA foreign_keys = ON');
}

// Re-export types and runner
export type { Migration, MigrationResult, SchemaVersionRow, ColumnInfo } from './types.js';
export { MigrationRunner, createMigrationRunner } from './runner.js';
