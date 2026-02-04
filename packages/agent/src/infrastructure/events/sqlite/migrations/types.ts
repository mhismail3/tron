/**
 * @fileoverview Migration Types
 *
 * Types for the database migration system.
 */

import type { Database } from 'bun:sqlite';

/**
 * A database migration
 */
export interface Migration {
  /** Unique version number (must be sequential) */
  version: number;
  /** Human-readable description */
  description: string;
  /** SQL to execute for the migration */
  up: (db: Database) => void;
}

/**
 * Schema version record from the database
 */
export interface SchemaVersionRow {
  version: number;
  applied_at: string;
  description: string | null;
}

/**
 * Result of running migrations
 */
export interface MigrationResult {
  /** Starting schema version before migrations */
  fromVersion: number;
  /** Final schema version after migrations */
  toVersion: number;
  /** Migrations that were applied */
  applied: number[];
  /** Whether any migrations were run */
  migrated: boolean;
}

/**
 * Column info from PRAGMA table_info
 */
export interface ColumnInfo {
  cid: number;
  name: string;
  type: string;
  notnull: number;
  dflt_value: string | null;
  pk: number;
}
