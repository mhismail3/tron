/**
 * @fileoverview Migration Runner
 *
 * Handles database schema migrations:
 * - Tracks applied migrations via schema_version table
 * - Runs pending migrations in order
 * - Supports incremental column additions
 */

import type { Database } from 'bun:sqlite';
import type { Migration, MigrationResult, SchemaVersionRow, ColumnInfo } from './types.js';

/**
 * Runs database migrations
 */
export class MigrationRunner {
  private readonly db: Database;
  private readonly migrations: Migration[];

  constructor(db: Database, migrations: Migration[]) {
    this.db = db;
    this.migrations = this.sortMigrations(migrations);
  }

  /**
   * Run all pending migrations
   */
  run(): MigrationResult {
    // Ensure schema_version table exists
    this.ensureVersionTable();

    const fromVersion = this.getCurrentVersion();
    const applied: number[] = [];

    for (const migration of this.migrations) {
      if (migration.version <= fromVersion) {
        continue;
      }

      migration.up(this.db);
      this.recordMigration(migration);
      applied.push(migration.version);
    }

    const toVersion = this.getCurrentVersion();

    return {
      fromVersion,
      toVersion,
      applied,
      migrated: applied.length > 0,
    };
  }

  /**
   * Get the current schema version
   */
  getCurrentVersion(): number {
    try {
      const row = this.db.prepare('SELECT MAX(version) as version FROM schema_version').get() as { version: number | null } | undefined;
      return row?.version ?? 0;
    } catch {
      // Table doesn't exist yet
      return 0;
    }
  }

  /**
   * Get list of column names for a table
   */
  getTableColumns(tableName: string): string[] {
    const columns = this.db.prepare(`PRAGMA table_info(${tableName})`).all() as ColumnInfo[];
    return columns.map(col => col.name);
  }

  /**
   * Check if a table exists
   * Note: bun:sqlite returns null for no rows, not undefined
   */
  tableExists(tableName: string): boolean {
    const row = this.db.prepare(`
      SELECT name FROM sqlite_master
      WHERE type='table' AND name=?
    `).get(tableName) as { name: string } | null;
    return row !== null;
  }

  /**
   * Check if a column exists in a table
   */
  columnExists(tableName: string, columnName: string): boolean {
    const columns = this.getTableColumns(tableName);
    return columns.includes(columnName);
  }

  /**
   * Add a column if it doesn't exist
   * @returns true if column was added, false if it already existed
   */
  addColumnIfNotExists(
    tableName: string,
    columnName: string,
    columnDef: string
  ): boolean {
    if (this.columnExists(tableName, columnName)) {
      return false;
    }
    this.db.exec(`ALTER TABLE ${tableName} ADD COLUMN ${columnName} ${columnDef}`);
    return true;
  }

  /**
   * Ensure the schema_version table exists
   */
  private ensureVersionTable(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL,
        description TEXT
      )
    `);
  }

  /**
   * Record that a migration was applied
   */
  private recordMigration(migration: Migration): void {
    this.db.prepare(`
      INSERT OR REPLACE INTO schema_version (version, applied_at, description)
      VALUES (?, datetime('now'), ?)
    `).run(migration.version, migration.description);
  }

  /**
   * Sort migrations by version number
   */
  private sortMigrations(migrations: Migration[]): Migration[] {
    return [...migrations].sort((a, b) => a.version - b.version);
  }

  /**
   * Get all applied migrations
   */
  getAppliedMigrations(): SchemaVersionRow[] {
    try {
      return this.db.prepare('SELECT * FROM schema_version ORDER BY version').all() as SchemaVersionRow[];
    } catch {
      return [];
    }
  }

  /**
   * Get pending migrations that haven't been applied yet
   */
  getPendingMigrations(): Migration[] {
    const currentVersion = this.getCurrentVersion();
    return this.migrations.filter(m => m.version > currentVersion);
  }
}

/**
 * Create a migration runner for the given database
 */
export function createMigrationRunner(
  db: Database,
  migrations: Migration[]
): MigrationRunner {
  return new MigrationRunner(db, migrations);
}
