/**
 * @fileoverview LoggerRegistry - Manages logger and transport lifecycle
 *
 * Eliminates global mutable state by encapsulating:
 * - SQLite transport initialization
 * - Default logger instance
 * - Configuration management
 *
 * Supports multiple independent registries for testing isolation.
 */

import type Database from 'better-sqlite3';
import { TronLogger } from './logger.js';
import { SQLiteTransport } from './sqlite-transport.js';
import type {
  LogContext,
  LoggerOptions,
  LoggerRegistryOptions,
  TransportOptions,
  ILoggerRegistry,
} from './types.js';

// Re-export types for backward compatibility
export type { LoggerRegistryOptions, TransportOptions } from './types.js';

// =============================================================================
// LoggerRegistry Class
// =============================================================================

/**
 * Registry for managing logger instances and SQLite transport.
 *
 * Encapsulates all mutable state for logging infrastructure,
 * enabling multiple independent registries for testing.
 */
export class LoggerRegistry implements ILoggerRegistry {
  private transport: SQLiteTransport | null = null;
  private rootLogger: TronLogger | null = null;
  private options: LoggerRegistryOptions;
  private closed = false;

  constructor(options: LoggerRegistryOptions = {}) {
    this.options = options;
  }

  /**
   * Initialize the SQLite transport for log persistence.
   * Call this once with the database instance.
   *
   * @param db - The better-sqlite3 database instance
   * @param options - Transport configuration options
   */
  initializeTransport(db: Database.Database, options?: TransportOptions): void {
    if (this.closed) {
      throw new Error('LoggerRegistry has been closed');
    }

    // Close existing transport if reinitializing
    if (this.transport) {
      this.transport.close();
    }

    this.transport = new SQLiteTransport(db, {
      minLevel: options?.minLevel ?? 30, // Default: info and above
      batchSize: options?.batchSize ?? 100,
      flushIntervalMs: options?.flushIntervalMs ?? 1000,
    });
  }

  /**
   * Get the SQLite transport (for internal use by TronLogger)
   */
  getTransport(): SQLiteTransport | null {
    return this.transport;
  }

  /**
   * Get or create the root logger instance
   */
  getLogger(options?: LoggerOptions): TronLogger {
    if (this.closed) {
      throw new Error('LoggerRegistry has been closed');
    }

    if (!this.rootLogger) {
      this.rootLogger = new TronLogger(
        {
          level: options?.level ?? this.options.level,
          pretty: options?.pretty ?? this.options.pretty,
          ...options,
        },
        {},
        this
      );
    }
    return this.rootLogger;
  }

  /**
   * Create a component-specific logger
   *
   * @param component - Component name for log context
   * @param context - Additional context to attach
   */
  createLogger(component: string, context?: LogContext): TronLogger {
    return this.getLogger().child({ component, ...context });
  }

  /**
   * Flush pending logs to database immediately
   */
  async flush(): Promise<void> {
    if (this.transport) {
      await this.transport.flush();
    }
  }

  /**
   * Close the registry and its transport
   */
  close(): void {
    if (this.closed) return;
    this.closed = true;

    if (this.transport) {
      this.transport.close();
      this.transport = null;
    }

    this.rootLogger = null;
  }

  /**
   * Reset the registry state (for testing)
   */
  reset(): void {
    if (this.transport) {
      this.transport.close();
      this.transport = null;
    }
    this.rootLogger = null;
    this.closed = false;
  }

  /**
   * Check if the registry has been closed
   */
  isClosed(): boolean {
    return this.closed;
  }

  /**
   * Check if a transport is configured
   */
  hasTransport(): boolean {
    return this.transport !== null;
  }
}

// =============================================================================
// Default Registry (Backward Compatibility)
// =============================================================================

let defaultRegistry: LoggerRegistry | null = null;

/**
 * Get the default (global) logger registry.
 * Creates one if it doesn't exist.
 */
export function getDefaultRegistry(): LoggerRegistry {
  if (!defaultRegistry) {
    defaultRegistry = new LoggerRegistry();
  }
  return defaultRegistry;
}

/**
 * Set a custom default registry (for testing)
 */
export function setDefaultRegistry(registry: LoggerRegistry | null): void {
  defaultRegistry = registry;
}

/**
 * Reset the default registry (for testing)
 */
export function resetDefaultRegistry(): void {
  if (defaultRegistry) {
    defaultRegistry.reset();
  }
  defaultRegistry = null;
}
