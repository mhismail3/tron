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

// =============================================================================
// Types
// =============================================================================

export type LogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal';

export interface LoggerOptions {
  level?: LogLevel;
  name?: string;
  pretty?: boolean;
  destination?: string;
}

export interface LogContext {
  sessionId?: string;
  component?: string;
  toolName?: string;
  [key: string]: unknown;
}

// Log level to numeric value mapping
const LOG_LEVEL_NUM: Record<LogLevel, number> = {
  trace: 10,
  debug: 20,
  info: 30,
  warn: 40,
  error: 50,
  fatal: 60,
};

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

  constructor(options: LoggerOptions = {}, context: LogContext = {}) {
    this.pino = createPinoLogger(options);
    this.context = context;
  }

  /**
   * Private constructor for child loggers - avoids creating new pino transport
   */
  private static fromPino(pinoLogger: pino.Logger, context: LogContext): TronLogger {
    const logger = Object.create(TronLogger.prototype) as TronLogger;
    logger.pino = pinoLogger;
    logger.context = context;
    return logger;
  }

  /**
   * Create a child logger with additional context
   * Reuses the parent's pino transport to avoid adding exit listeners
   */
  child(context: LogContext): TronLogger {
    const mergedContext = { ...this.context, ...context };
    return TronLogger.fromPino(this.pino.child(context), mergedContext);
  }

  /**
   * Write to SQLite transport with full context
   */
  private writeToSqlite(level: LogLevel, msg: string, data?: Record<string, unknown>, err?: Error): void {
    if (!globalSqliteTransport) return;

    try {
      // Merge logger context with AsyncLocalStorage context
      const asyncContext = getLoggingContext();

      globalSqliteTransport.write({
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
        // Error info
        err,
      }).catch(() => {
        // Ignore errors - resilience
      });
    } catch {
      // Ignore errors - logging should never fail
    }
  }

  /**
   * Log at trace level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  trace(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (typeof msgOrDataSecond === 'object') {
        this.pino.trace(msgOrDataSecond, msgOrData);
        this.writeToSqlite('trace', msgOrData, msgOrDataSecond);
      } else {
        this.pino.trace(msgOrData);
        this.writeToSqlite('trace', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '';
      this.pino.trace(msgOrData, msg);
      this.writeToSqlite('trace', msg, msgOrData);
    }
  }

  /**
   * Log at debug level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  debug(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (typeof msgOrDataSecond === 'object') {
        this.pino.debug(msgOrDataSecond, msgOrData);
        this.writeToSqlite('debug', msgOrData, msgOrDataSecond);
      } else {
        this.pino.debug(msgOrData);
        this.writeToSqlite('debug', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '';
      this.pino.debug(msgOrData, msg);
      this.writeToSqlite('debug', msg, msgOrData);
    }
  }

  /**
   * Log at info level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  info(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (typeof msgOrDataSecond === 'object') {
        this.pino.info(msgOrDataSecond, msgOrData);
        this.writeToSqlite('info', msgOrData, msgOrDataSecond);
      } else {
        this.pino.info(msgOrData);
        this.writeToSqlite('info', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '';
      this.pino.info(msgOrData, msg);
      this.writeToSqlite('info', msg, msgOrData);
    }
  }

  /**
   * Log at warn level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  warn(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (typeof msgOrDataSecond === 'object') {
        this.pino.warn(msgOrDataSecond, msgOrData);
        this.writeToSqlite('warn', msgOrData, msgOrDataSecond);
      } else {
        this.pino.warn(msgOrData);
        this.writeToSqlite('warn', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '';
      this.pino.warn(msgOrData, msg);
      this.writeToSqlite('warn', msg, msgOrData);
    }
  }

  /**
   * Log at error level
   * Supports: (msg), (msg, data), (msg, error), and (data, msg) signatures
   */
  error(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (msgOrDataOrError instanceof Error) {
        this.pino.error({ err: msgOrDataOrError }, msgOrData);
        this.writeToSqlite('error', msgOrData, undefined, msgOrDataOrError);
      } else if (typeof msgOrDataOrError === 'object') {
        this.pino.error(msgOrDataOrError, msgOrData);
        this.writeToSqlite('error', msgOrData, msgOrDataOrError);
      } else {
        this.pino.error(msgOrData);
        this.writeToSqlite('error', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataOrError === 'string' ? msgOrDataOrError : '';
      this.pino.error(msgOrData, msg);
      this.writeToSqlite('error', msg, msgOrData);
    }
  }

  /**
   * Log at fatal level
   * Supports: (msg), (msg, data), (msg, error), and (data, msg) signatures
   */
  fatal(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (msgOrDataOrError instanceof Error) {
        this.pino.fatal({ err: msgOrDataOrError }, msgOrData);
        this.writeToSqlite('fatal', msgOrData, undefined, msgOrDataOrError);
      } else if (typeof msgOrDataOrError === 'object') {
        this.pino.fatal(msgOrDataOrError, msgOrData);
        this.writeToSqlite('fatal', msgOrData, msgOrDataOrError);
      } else {
        this.pino.fatal(msgOrData);
        this.writeToSqlite('fatal', msgOrData);
      }
    } else {
      const msg = typeof msgOrDataOrError === 'string' ? msgOrDataOrError : '';
      this.pino.fatal(msgOrData, msg);
      this.writeToSqlite('fatal', msg, msgOrData);
    }
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
