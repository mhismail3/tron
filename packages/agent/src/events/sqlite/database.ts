/**
 * @fileoverview SQLite Database Connection Management
 *
 * Handles database connection lifecycle, configuration, and pragma setup.
 * This module is responsible for:
 * - Opening and closing database connections
 * - Configuring SQLite pragmas (WAL, foreign keys, cache)
 * - Providing access to the underlying database instance
 */

import Database from 'better-sqlite3';
import type { DatabaseConfig, DatabaseState } from './types.js';

/**
 * Default database configuration values
 */
export const DEFAULT_CONFIG = {
  enableWAL: true,
  busyTimeout: 5000,
  cacheSize: 64000, // 64MB
} as const;

/**
 * Manages SQLite database connection lifecycle
 */
export class DatabaseConnection {
  private state: DatabaseState;
  private readonly dbPath: string;

  constructor(dbPath: string, config?: Partial<DatabaseConfig>) {
    this.dbPath = dbPath;
    this.state = {
      db: null,
      initialized: false,
      config: {
        dbPath,
        enableWAL: config?.enableWAL ?? DEFAULT_CONFIG.enableWAL,
        busyTimeout: config?.busyTimeout ?? DEFAULT_CONFIG.busyTimeout,
        cacheSize: config?.cacheSize ?? DEFAULT_CONFIG.cacheSize,
      },
    };
  }

  /**
   * Open the database connection and configure pragmas
   */
  open(): Database.Database {
    if (this.state.db) {
      return this.state.db;
    }

    const db = new Database(this.dbPath);
    this.configurePragmas(db);
    this.state.db = db;

    return db;
  }

  /**
   * Mark the database as initialized (migrations complete)
   */
  markInitialized(): void {
    this.state.initialized = true;
  }

  /**
   * Close the database connection
   */
  close(): void {
    if (this.state.db) {
      // Run optimize to update query planner statistics before closing
      try {
        this.state.db.pragma('optimize');
      } catch {
        // Ignore errors during optimize (database might be in unexpected state)
      }
      this.state.db.close();
      this.state.db = null;
      this.state.initialized = false;
    }
  }

  /**
   * Check if database is initialized
   */
  isInitialized(): boolean {
    return this.state.initialized;
  }

  /**
   * Check if database connection is open
   */
  isOpen(): boolean {
    return this.state.db !== null;
  }

  /**
   * Get the database instance
   * @throws Error if database not initialized
   */
  getDatabase(): Database.Database {
    if (!this.state.db) {
      throw new Error('Database not initialized. Call initialize() first.');
    }
    return this.state.db;
  }

  /**
   * Get database path
   */
  getPath(): string {
    return this.dbPath;
  }

  /**
   * Get current configuration
   */
  getConfig(): DatabaseConfig {
    return { ...this.state.config };
  }

  /**
   * Configure SQLite pragmas for optimal performance
   */
  private configurePragmas(db: Database.Database): void {
    const { enableWAL, busyTimeout, cacheSize } = this.state.config;

    // WAL mode for better concurrent access
    if (enableWAL) {
      db.pragma('journal_mode = WAL');
      // Better write batching for WAL mode
      db.pragma('wal_autocheckpoint = 2000');
    }

    // Busy timeout for handling locked database
    db.pragma(`busy_timeout = ${busyTimeout}`);

    // Enable foreign key constraints
    db.pragma('foreign_keys = ON');

    // Balance between durability and performance
    db.pragma('synchronous = NORMAL');

    // Set cache size (negative = KB, positive = pages)
    db.pragma(`cache_size = -${cacheSize}`);

    // Store temp tables in memory for better performance
    db.pragma('temp_store = MEMORY');

    // Enable memory-mapped I/O (256MB) for faster reads
    db.pragma('mmap_size = 268435456');
  }

  /**
   * Execute a function within a transaction
   * Note: better-sqlite3 transactions are synchronous
   */
  transaction<T>(fn: () => T): T {
    const db = this.getDatabase();
    return db.transaction(fn)();
  }

  /**
   * Execute an async function with manual transaction control
   * Uses BEGIN/COMMIT/ROLLBACK for async operations.
   *
   * Note: If a transaction is already in progress, executes without
   * a new transaction to avoid nested transaction errors.
   */
  async transactionAsync<T>(fn: () => Promise<T>): Promise<T> {
    const db = this.getDatabase();

    // Check if already in a transaction
    if (db.inTransaction) {
      return fn();
    }

    db.exec('BEGIN IMMEDIATE');
    try {
      const result = await fn();
      db.exec('COMMIT');
      return result;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }
}
