/**
 * @fileoverview Trace ID Columns Migration
 *
 * Adds trace correlation columns to the logs table for sub-agent tracking:
 * - trace_id: Unique identifier for each operation
 * - parent_trace_id: Links child operations to parent operations
 * - depth: Nesting level (0 = root, 1 = first sub-agent, etc.)
 *
 * This enables queries like:
 * - Find all logs for a specific trace and its children
 * - Trace execution paths through sub-agents
 * - Filter logs by nesting depth
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 5,
  description: 'Add trace correlation columns to logs table',
  up: (db) => {
    // Use IF NOT EXISTS-style checks for idempotency
    // SQLite doesn't support ADD COLUMN IF NOT EXISTS, so we check the schema first
    const columns = db
      .prepare("PRAGMA table_info(logs)")
      .all() as { name: string }[];
    const columnNames = new Set(columns.map(c => c.name));

    // Add trace_id column if it doesn't exist
    if (!columnNames.has('trace_id')) {
      db.exec(`ALTER TABLE logs ADD COLUMN trace_id TEXT`);
    }

    // Add parent_trace_id column if it doesn't exist
    if (!columnNames.has('parent_trace_id')) {
      db.exec(`ALTER TABLE logs ADD COLUMN parent_trace_id TEXT`);
    }

    // Add depth column if it doesn't exist
    if (!columnNames.has('depth')) {
      db.exec(`ALTER TABLE logs ADD COLUMN depth INTEGER DEFAULT 0`);
    }

    // Create indexes (IF NOT EXISTS handles idempotency)
    db.exec(`
      -- Index for finding all logs in a trace
      CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);

      -- Index for finding child operations by parent
      CREATE INDEX IF NOT EXISTS idx_logs_parent_trace ON logs(parent_trace_id);
    `);
  },
};
