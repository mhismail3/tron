/**
 * @fileoverview SQLite Database Connection Management
 *
 * Handles database connection lifecycle, configuration, and pragma setup.
 * This module is responsible for:
 * - Opening and closing database connections
 * - Configuring SQLite pragmas (WAL, foreign keys, cache)
 * - Providing access to the underlying database instance
 */

import { Database } from 'bun:sqlite';
import { AsyncLocalStorage } from 'async_hooks';
import { existsSync } from 'fs';
import type { DatabaseConfig, DatabaseState } from './types.js';

/**
 * Check if running in test environment (Vitest or NODE_ENV=test)
 */
function isTestEnvironment(): boolean {
  return process.env.VITEST === 'true' || process.env.NODE_ENV === 'test';
}

// =============================================================================
// Custom SQLite for macOS (extension loading support)
// =============================================================================

/**
 * macOS ships SQLite with extension loading disabled. Use Homebrew's vanilla
 * build to enable sqlite-vec. This must be called before any Database instances.
 */
let customSqliteConfigured = false;

function configureCustomSqlite(): void {
  if (customSqliteConfigured) return;
  customSqliteConfigured = true;

  if (process.platform !== 'darwin') return;
  if (isTestEnvironment()) return;

  const HOMEBREW_SQLITE_ARM = '/opt/homebrew/opt/sqlite3/lib/libsqlite3.dylib';
  const HOMEBREW_SQLITE_INTEL = '/usr/local/opt/sqlite3/lib/libsqlite3.dylib';
  const sqlitePath = existsSync(HOMEBREW_SQLITE_ARM) ? HOMEBREW_SQLITE_ARM
    : existsSync(HOMEBREW_SQLITE_INTEL) ? HOMEBREW_SQLITE_INTEL
    : null;

  if (sqlitePath && typeof Database.setCustomSQLite === 'function') {
    try {
      Database.setCustomSQLite(sqlitePath);
    } catch {
      // Ignore — if it fails, extension loading won't work but everything else will
    }
  }
}

configureCustomSqlite();

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
  private readonly transactionContext = new AsyncLocalStorage<boolean>();
  private transactionQueue: Promise<void> = Promise.resolve();
  private managedTransactionActive = false;

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
  open(): Database {
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
        this.state.db.run('PRAGMA optimize');
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
  getDatabase(): Database {
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
  private configurePragmas(db: Database): void {
    const { enableWAL, busyTimeout, cacheSize } = this.state.config;

    // WAL mode for better concurrent access
    if (enableWAL) {
      db.run('PRAGMA journal_mode = WAL');
      // Better write batching for WAL mode
      db.run('PRAGMA wal_autocheckpoint = 2000');
    }

    // Busy timeout for handling locked database
    db.run(`PRAGMA busy_timeout = ${busyTimeout}`);

    // Enable foreign key constraints
    db.run('PRAGMA foreign_keys = ON');

    // Balance between durability and performance
    db.run('PRAGMA synchronous = NORMAL');

    // Set cache size (negative = KB, positive = pages)
    db.run(`PRAGMA cache_size = -${cacheSize}`);

    // Memory settings: minimize for tests to prevent OOM in Vitest workers
    if (isTestEnvironment()) {
      db.run('PRAGMA temp_store = DEFAULT'); // Use disk for temp tables in tests
      db.run('PRAGMA mmap_size = 0'); // Disable memory-mapped I/O
    } else {
      db.run('PRAGMA temp_store = MEMORY'); // Store temp tables in memory for production
      db.run('PRAGMA mmap_size = 268435456'); // 256MB memory-mapped I/O for production
    }
  }

  /**
   * Execute a function within a transaction
   * Note: bun:sqlite transactions are synchronous
   */
  transaction<T>(fn: () => T): T {
    const db = this.getDatabase();
    return db.transaction(fn)();
  }

  /**
   * Execute an async function with manual transaction control
   * Uses BEGIN/COMMIT/ROLLBACK for async operations.
   *
   * Nested calls in the same async chain reuse the outer transaction.
   * Concurrent top-level calls are serialized to avoid interleaved writes
   * on the shared SQLite connection.
   */
  async transactionAsync<T>(fn: () => Promise<T>): Promise<T> {
    if (this.transactionContext.getStore()) {
      return fn();
    }

    const db = this.getDatabase();
    if (db.inTransaction && !this.managedTransactionActive) {
      return fn();
    }

    const previous = this.transactionQueue;
    let releaseQueue: (() => void) | undefined;
    this.transactionQueue = new Promise<void>((resolve) => {
      releaseQueue = resolve;
    });

    await previous;
    try {
      return await this.transactionContext.run(true, async () => {
        this.managedTransactionActive = true;
        db.exec('BEGIN IMMEDIATE');
        try {
          const result = await fn();
          db.exec('COMMIT');
          return result;
        } catch (error) {
          db.exec('ROLLBACK');
          throw error;
        } finally {
          this.managedTransactionActive = false;
        }
      });
    } finally {
      releaseQueue?.();
    }
  }
}
