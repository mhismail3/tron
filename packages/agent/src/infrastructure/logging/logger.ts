/**
 * @fileoverview Centralized logging infrastructure for Tron
 *
 * Uses pino for structured logging with:
 * - Configurable log levels
 * - JSON output for production
 * - Pretty printing for development
 * - Context-aware child loggers
 * - Performance tracking
 * - SQLite persistence for queryable log history
 */

import pino from 'pino';
import type Database from 'better-sqlite3';
import { SQLiteTransport } from './sqlite-transport.js';
import { getLoggingContext } from './log-context.js';
import {
  LOG_LEVEL_NUM,
  type LogLevel,
  type LoggerOptions,
  type LogContext,
  type ILoggerRegistry,
} from './types.js';

// Re-export types for backward compatibility
export type { LogLevel, LoggerOptions, LogContext } from './types.js';

// =============================================================================
// Global SQLite Transport
// =============================================================================

let globalSqliteTransport: SQLiteTransport | null = null;

/**
 * Initialize the SQLite transport for log persistence.
 * Call this once at server startup with the database instance.
 *
 * @param db - The better-sqlite3 database instance (the event store database)
 * @param options - Transport configuration options
 */
export function initializeLogTransport(
  db: Database.Database,
  options?: {
    minLevel?: number;
    batchSize?: number;
    flushIntervalMs?: number;
  }
): void {
  if (globalSqliteTransport) {
    globalSqliteTransport.close();
  }

  globalSqliteTransport = new SQLiteTransport(db, {
    minLevel: options?.minLevel ?? 30, // Default: info and above
    batchSize: options?.batchSize ?? 100,
    flushIntervalMs: options?.flushIntervalMs ?? 1000,
  });
}

/**
 * Close the SQLite transport (for shutdown)
 */
export function closeLogTransport(): void {
  if (globalSqliteTransport) {
    globalSqliteTransport.close();
    globalSqliteTransport = null;
  }
}

/**
 * Flush pending logs to database immediately
 */
export async function flushLogs(): Promise<void> {
  if (globalSqliteTransport) {
    await globalSqliteTransport.flush();
  }
}

// =============================================================================
// Logger Factory
// =============================================================================

/**
 * Create a configured pino logger instance
 */
function createPinoLogger(options: LoggerOptions = {}): pino.Logger {
  // Default to 'warn' to avoid noisy INFO logs in interactive mode
  // Use LOG_LEVEL=info or LOG_LEVEL=debug for verbose output
  const level = options.level ?? (process.env.LOG_LEVEL as LogLevel) ?? 'warn';
  const pretty = options.pretty ?? process.env.NODE_ENV !== 'production';

  const pinoOptions: pino.LoggerOptions = {
    level,
    name: options.name ?? 'tron',
    timestamp: pino.stdTimeFunctions.isoTime,
    formatters: {
      level: (label) => ({ level: label }),
      bindings: (bindings) => ({
        pid: bindings.pid,
        host: bindings.hostname,
        name: bindings.name,
      }),
    },
  };

  if (pretty) {
    return pino({
      ...pinoOptions,
      transport: {
        target: 'pino-pretty',
        options: {
          colorize: true,
          translateTime: 'HH:MM:ss.l',
          ignore: 'pid,hostname',
          destination: 2, // stderr - critical for TUI compatibility
        },
      },
    });
  }

  // JSON mode also goes to stderr to avoid interfering with TUI
  return pino(pinoOptions, pino.destination(2));
}

// =============================================================================
// Logger Wrapper Class
// =============================================================================

export class TronLogger {
  private pino: pino.Logger;
  private context: LogContext;
  private registry: ILoggerRegistry | null;

  constructor(options: LoggerOptions = {}, context: LogContext = {}, registry?: ILoggerRegistry) {
    this.pino = createPinoLogger(options);
    this.context = context;
    this.registry = registry ?? null;
  }

  /**
   * Private constructor for child loggers - avoids creating new pino transport
   */
  private static fromPino(pinoLogger: pino.Logger, context: LogContext, registry: ILoggerRegistry | null): TronLogger {
    const logger = Object.create(TronLogger.prototype) as TronLogger;
    logger.pino = pinoLogger;
    logger.context = context;
    logger.registry = registry;
    return logger;
  }

  /**
   * Create a child logger with additional context
   * Reuses the parent's pino transport to avoid adding exit listeners
   */
  child(context: LogContext): TronLogger {
    const mergedContext = { ...this.context, ...context };
    return TronLogger.fromPino(this.pino.child(context), mergedContext, this.registry);
  }

  /**
   * Write to SQLite transport with full context
   * Uses registry transport if available, falls back to global transport.
   * On failure, logs structured JSON to stderr as fallback.
   */
  private writeToSqlite(level: LogLevel, msg: string, data?: Record<string, unknown>, err?: Error): void {
    // Use registry transport if available (test isolation), otherwise global transport (production)
    const transport = this.registry?.getTransport() ?? globalSqliteTransport;
    if (!transport) return;

    try {
      // Merge logger context with AsyncLocalStorage context
      const asyncContext = getLoggingContext();

      transport.write({
        level: LOG_LEVEL_NUM[level],
        time: Date.now(),
        msg,
        component: this.context.component ?? 'unknown',
        // Context from logger.child()
        sessionId: this.context.sessionId as string | undefined,
        // Context from AsyncLocalStorage (overrides logger context)
        ...asyncContext,
        // Additional data fields
        ...data,
        // Error info (only include if defined, to not override data.err)
        ...(err !== undefined && { err }),
      }).catch((transportErr) => {
        // Log to stderr as fallback with structured JSON
        console.error('[LOG_TRANSPORT_FALLBACK]', JSON.stringify({
          ts: new Date().toISOString(),
          level,
          msg,
          component: this.context.component,
          traceId: asyncContext.traceId,
          transportError: transportErr instanceof Error ? transportErr.message : String(transportErr),
        }));
      });
    } catch (syncErr) {
      // Log to stderr as fallback with structured JSON
      console.error('[LOG_TRANSPORT_FALLBACK]', JSON.stringify({
        ts: new Date().toISOString(),
        level,
        msg,
        component: this.context.component,
        syncError: syncErr instanceof Error ? syncErr.message : String(syncErr),
      }));
    }
  }

  /**
   * Normalize log arguments and dispatch to pino and SQLite.
   * Handles all signature variants: (msg), (msg, data), (data, msg), (msg, error)
   */
  private dispatch(
    level: LogLevel,
    msgOrData: string | Record<string, unknown>,
    second?: string | Error | Record<string, unknown>,
    supportsError = false
  ): void {
    const pinoFn = this.pino[level].bind(this.pino);

    if (typeof msgOrData === 'string') {
      // First arg is string message
      if (supportsError && second instanceof Error) {
        // (msg, error) signature
        pinoFn({ err: second }, msgOrData);
        this.writeToSqlite(level, msgOrData, undefined, second);
      } else if (typeof second === 'object' && second !== null) {
        // (msg, data) signature
        pinoFn(second as Record<string, unknown>, msgOrData);
        this.writeToSqlite(level, msgOrData, second as Record<string, unknown>);
      } else {
        // (msg) signature only
        pinoFn(msgOrData);
        this.writeToSqlite(level, msgOrData);
      }
    } else {
      // First arg is data object: (data, msg) signature
      const msg = typeof second === 'string' ? second : '';
      pinoFn(msgOrData, msg);
      this.writeToSqlite(level, msg, msgOrData);
    }
  }

  /**
   * Log at trace level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  trace(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    this.dispatch('trace', msgOrData, msgOrDataSecond);
  }

  /**
   * Log at debug level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  debug(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    this.dispatch('debug', msgOrData, msgOrDataSecond);
  }

  /**
   * Log at info level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  info(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    this.dispatch('info', msgOrData, msgOrDataSecond);
  }

  /**
   * Log at warn level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  warn(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    this.dispatch('warn', msgOrData, msgOrDataSecond);
  }

  /**
   * Log at error level
   * Supports: (msg), (msg, data), (msg, error), and (data, msg) signatures
   */
  error(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void {
    this.dispatch('error', msgOrData, msgOrDataOrError, true);
  }

  /**
   * Log at fatal level
   * Supports: (msg), (msg, data), (msg, error), and (data, msg) signatures
   */
  fatal(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void {
    this.dispatch('fatal', msgOrData, msgOrDataOrError, true);
  }

  /**
   * Start a timer for performance tracking
   */
  startTimer(label: string): () => void {
    const start = performance.now();
    return () => {
      const duration = performance.now() - start;
      this.debug({ durationMs: duration.toFixed(2) }, `${label} completed`);
    };
  }

  /**
   * Log with timing wrapper
   */
  async timed<T>(
    label: string,
    fn: () => Promise<T>,
    level: LogLevel = 'debug'
  ): Promise<T> {
    const start = performance.now();
    try {
      const result = await fn();
      const duration = performance.now() - start;
      const data = { durationMs: duration.toFixed(2) };
      const msg = `${label} completed`;
      this.pino[level](data, msg);
      this.writeToSqlite(level, msg, data);
      return result;
    } catch (error) {
      const duration = performance.now() - start;
      const err = error instanceof Error ? error : new Error(String(error));
      this.error(`${label} failed`, {
        durationMs: duration.toFixed(2),
        err,
      });
      throw error;
    }
  }
}

// =============================================================================
// Singleton Logger
// =============================================================================

let defaultLogger: TronLogger | null = null;

/**
 * Get the default logger instance
 */
export function getLogger(options?: LoggerOptions): TronLogger {
  if (!defaultLogger) {
    defaultLogger = new TronLogger(options);
  }
  return defaultLogger;
}

/**
 * Create a component-specific logger
 */
export function createLogger(component: string, context?: LogContext): TronLogger {
  return getLogger().child({ component, ...context });
}

/**
 * Reset the default logger (for testing)
 */
export function resetLogger(): void {
  defaultLogger = null;
}
