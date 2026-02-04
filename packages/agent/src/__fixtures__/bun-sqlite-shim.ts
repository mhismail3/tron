/**
 * @fileoverview bun:sqlite shim for vitest
 *
 * This module provides a compatibility layer that maps bun:sqlite API to better-sqlite3
 * for running tests in Node.js (vitest). In production, Bun's native bun:sqlite is used.
 *
 * Key differences handled:
 * - get() returns null in bun:sqlite vs undefined in better-sqlite3
 * - Blob columns return Uint8Array in bun:sqlite vs Buffer in better-sqlite3
 * - changes property includes trigger operations in bun:sqlite
 */

import BetterSqlite3, { type Database as BetterSqliteDatabase, type Statement as BetterSqliteStatement } from 'better-sqlite3';

// Re-export types that match bun:sqlite's API
export type SQLQueryBindings =
  | string
  | bigint
  | Uint8Array
  | number
  | boolean
  | null
  | Record<string, string | bigint | Uint8Array | number | boolean | null>;

/**
 * Wrapper around better-sqlite3's Statement to match bun:sqlite behavior
 */
class StatementWrapper {
  private stmt: BetterSqliteStatement;

  constructor(stmt: BetterSqliteStatement) {
    this.stmt = stmt;
  }

  /**
   * Run the statement and return changes info
   * Note: bun:sqlite includes trigger changes, better-sqlite3 does not
   * Tests should account for this difference
   */
  run(...params: SQLQueryBindings[]): { changes: number; lastInsertRowid: number | bigint } {
    const result = this.stmt.run(...params);
    return {
      changes: result.changes,
      lastInsertRowid: result.lastInsertRowid,
    };
  }

  /**
   * Get first row - returns null if no rows (matching bun:sqlite behavior)
   */
  get(...params: SQLQueryBindings[]): unknown {
    const result = this.stmt.get(...params);
    return result === undefined ? null : result;
  }

  /**
   * Get all rows
   */
  all(...params: SQLQueryBindings[]): unknown[] {
    return this.stmt.all(...params);
  }

  /**
   * Finalize the statement
   */
  finalize(): void {
    // better-sqlite3 doesn't have finalize, statements are auto-finalized
  }
}

/**
 * Database wrapper that matches bun:sqlite API
 */
export class Database {
  private db: BetterSqliteDatabase;

  constructor(filename: string, options?: { readonly?: boolean }) {
    this.db = new BetterSqlite3(filename, options);
  }

  /**
   * Check if database is in a transaction
   */
  get inTransaction(): boolean {
    return this.db.inTransaction;
  }

  /**
   * Prepare a statement
   */
  prepare(sql: string): StatementWrapper {
    return new StatementWrapper(this.db.prepare(sql));
  }

  /**
   * Shorthand for prepare().get()
   */
  query(sql: string): { get: (...params: SQLQueryBindings[]) => unknown } {
    const stmt = this.prepare(sql);
    return {
      get: (...params: SQLQueryBindings[]) => stmt.get(...params),
    };
  }

  /**
   * Execute SQL that modifies data
   */
  run(sql: string, ...params: SQLQueryBindings[]): { changes: number; lastInsertRowid: number | bigint } {
    return this.prepare(sql).run(...params);
  }

  /**
   * Execute raw SQL (DDL, multiple statements)
   */
  exec(sql: string): void {
    this.db.exec(sql);
  }

  /**
   * Create a transaction wrapper
   */
  transaction<T>(fn: () => T): () => T {
    const wrapped = this.db.transaction(fn);
    return () => wrapped();
  }

  /**
   * Close the database
   */
  close(): void {
    this.db.close();
  }
}

// Re-export Statement type
export type Statement = StatementWrapper;

// Default export for compatibility
export default Database;
