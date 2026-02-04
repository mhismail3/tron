/**
 * @fileoverview Base Repository
 *
 * Provides common utilities and patterns shared across all repositories:
 * - Database access
 * - ID generation
 * - Timestamp creation
 * - Common query patterns
 */

import * as crypto from 'crypto';
import type { Database, SQLQueryBindings } from 'bun:sqlite';
import type { DatabaseConnection } from '../database.js';

/** Result of a run() query */
interface RunResult {
  changes: number;
  lastInsertRowid: number | bigint;
}

/**
 * Base class for all repositories
 *
 * Repositories handle data access for a specific domain entity.
 * They encapsulate SQL queries and row-to-entity conversions.
 */
export abstract class BaseRepository {
  protected readonly connection: DatabaseConnection;

  constructor(connection: DatabaseConnection) {
    this.connection = connection;
  }

  /**
   * Get the underlying database instance
   */
  protected get db(): Database {
    return this.connection.getDatabase();
  }

  /**
   * Generate a unique ID with optional prefix
   * @param prefix - Prefix for the ID (e.g., 'sess', 'ws', 'evt')
   * @param length - Length of the random portion (default: 12)
   */
  protected generateId(prefix: string, length = 12): string {
    const random = crypto.randomUUID().replace(/-/g, '').slice(0, length);
    return `${prefix}_${random}`;
  }

  /**
   * Get current ISO timestamp
   */
  protected now(): string {
    return new Date().toISOString();
  }

  /**
   * Execute a query and return all results
   */
  protected all<T>(sql: string, ...params: SQLQueryBindings[]): T[] {
    return this.db.prepare(sql).all(...params) as T[];
  }

  /**
   * Execute a query and return the first result
   * Note: bun:sqlite returns null for no rows, we normalize to undefined
   */
  protected get<T>(sql: string, ...params: SQLQueryBindings[]): T | undefined {
    const result = this.db.prepare(sql).get(...params);
    return (result ?? undefined) as T | undefined;
  }

  /**
   * Execute a query that modifies data
   */
  protected run(sql: string, ...params: SQLQueryBindings[]): RunResult {
    return this.db.prepare(sql).run(...params);
  }

  /**
   * Execute raw SQL (for DDL statements)
   */
  protected exec(sql: string): void {
    this.db.exec(sql);
  }

  /**
   * Build IN clause placeholders for array parameters
   * @param items - Array of items to create placeholders for
   * @returns Comma-separated question marks
   */
  protected inPlaceholders(items: unknown[]): string {
    return items.map(() => '?').join(',');
  }

  /**
   * Execute within a synchronous transaction
   */
  protected transaction<T>(fn: () => T): T {
    return this.connection.transaction(fn);
  }

  /**
   * Execute within an async transaction
   */
  protected async transactionAsync<T>(fn: () => Promise<T>): Promise<T> {
    return this.connection.transactionAsync(fn);
  }
}

/**
 * Utility functions that don't require database access
 */
export const idUtils = {
  /**
   * Generate a UUID-based ID
   */
  generate(prefix: string, length = 12): string {
    const random = crypto.randomUUID().replace(/-/g, '').slice(0, length);
    return `${prefix}_${random}`;
  },

  /**
   * Generate ID for workspaces
   */
  workspace(): string {
    return this.generate('ws');
  },

  /**
   * Generate ID for sessions
   */
  session(): string {
    return this.generate('sess');
  },

  /**
   * Generate ID for events
   */
  event(): string {
    return this.generate('evt');
  },

  /**
   * Generate ID for branches
   */
  branch(): string {
    return this.generate('br');
  },

  /**
   * Generate ID for blobs
   */
  blob(): string {
    return this.generate('blob');
  },
};

/**
 * Common row conversion utilities
 */
export const rowUtils = {
  /**
   * Parse JSON string to object, with fallback
   */
  parseJson<T>(json: string | null, fallback: T): T {
    if (!json) return fallback;
    try {
      return JSON.parse(json) as T;
    } catch {
      return fallback;
    }
  },

  /**
   * Convert SQLite boolean (0/1) to JavaScript boolean
   */
  toBoolean(value: number | null): boolean {
    return value === 1;
  },

  /**
   * Convert JavaScript boolean to SQLite boolean (0/1)
   */
  fromBoolean(value: boolean): number {
    return value ? 1 : 0;
  },
};
