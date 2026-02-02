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
 * Check if running in test environment (Vitest or NODE_ENV=test)
 */
function isTestEnvironment(): boolean {
  return process.env.VITEST === 'true' || process.env.NODE_ENV === 'test';
}

/**
 * Default database configuration values (production)
 */
export const DEFAULT_CONFIG = {
  enableWAL: true,
  busyTimeout: 5000,
  cacheSize: 64000, // 64MB
} as const;

/**
 * Test-optimized configuration (minimal memory footprint)
 * Reduces memory per connection from ~320MB to ~500KB to prevent OOM in Vitest workers
 */
export const TEST_CONFIG = {
  enableWAL: true,
  busyTimeout: 5000,
  cacheSize: 500, // 500KB - 128x smaller than production
} as const;

/**
 * Get appropriate config based on environment
 */
export function getDefaultConfig(): { enableWAL: boolean; busyTimeout: number; cacheSize: number } {
  return isTestEnvironment() ? TEST_CONFIG : DEFAULT_CONFIG;
}

/**
 * Manages SQLite database connection lifecycle
 */
export class DatabaseConnection {
  private state: DatabaseState;
  private readonly dbPath: string;

  constructor(dbPath: string, config?: Partial<DatabaseConfig>) {
    this.dbPath = dbPath;
    const defaults = getDefaultConfig();
    this.state = {
      db: null,
      initialized: false,
      config: {
        dbPath,
        enableWAL: config?.enableWAL ?? defaults.enableWAL,
        busyTimeout: config?.busyTimeout ?? defaults.busyTimeout,
        cacheSize: config?.cacheSize ?? defaults.cacheSize,
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

    // Memory settings: minimize for tests to prevent OOM in Vitest workers
    if (isTestEnvironment()) {
      db.pragma('temp_store = DEFAULT'); // Use disk for temp tables in tests
      db.pragma('mmap_size = 0'); // Disable memory-mapped I/O
    } else {
      db.pragma('temp_store = MEMORY'); // Store temp tables in memory for production
      db.pragma('mmap_size = 268435456'); // 256MB memory-mapped I/O for production
    }
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
