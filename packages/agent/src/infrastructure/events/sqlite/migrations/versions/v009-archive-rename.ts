/**
 * @fileoverview Rename ended_at → archived_at
 *
 * Renames the sessions.ended_at column to archived_at to reflect
 * the new archive semantics (soft-delete, reversible).
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 9,
  description: 'Rename sessions ended_at to archived_at',
  up: (db) => {
    // Check if already renamed (fresh DBs created with v001 have archived_at)
    const columns = db.prepare("PRAGMA table_info('sessions')").all() as { name: string }[];
    const hasEndedAt = columns.some(c => c.name === 'ended_at');

    if (!hasEndedAt) {
      // Already has archived_at (fresh DB) — just ensure index name is correct
      db.exec(`
        CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived_at);
      `);
      return;
    }

    // Rename column (SQLite 3.25+)
    db.exec(`
      ALTER TABLE sessions RENAME COLUMN ended_at TO archived_at;

      -- Rename index: drop old, create new
      DROP INDEX IF EXISTS idx_sessions_ended;
      DROP INDEX IF EXISTS idx_sessions_archived;
      CREATE INDEX idx_sessions_archived ON sessions(archived_at);

      -- Fix spawning index that referenced ended_at
      DROP INDEX IF EXISTS idx_sessions_spawning;
      CREATE INDEX idx_sessions_spawning ON sessions(spawning_session_id, archived_at);
    `);
  },
};
