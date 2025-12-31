/**
 * @fileoverview Centralized logging infrastructure for Tron
 *
 * Uses pino for structured logging with:
 * - Configurable log levels
 * - JSON output for production
 * - Pretty printing for development
 * - Context-aware child loggers
 * - Performance tracking
 */

import pino from 'pino';

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

// =============================================================================
// Logger Factory
// =============================================================================

/**
 * Create a configured pino logger instance
 */
function createPinoLogger(options: LoggerOptions = {}): pino.Logger {
  const level = options.level ?? (process.env.LOG_LEVEL as LogLevel) ?? 'info';
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
        },
      },
    });
  }

  return pino(pinoOptions);
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
   * Create a child logger with additional context
   */
  child(context: LogContext): TronLogger {
    const childLogger = new TronLogger({}, { ...this.context, ...context });
    childLogger.pino = this.pino.child(context);
    return childLogger;
  }

  /**
   * Log at trace level
   */
  trace(msg: string, data?: Record<string, unknown>): void {
    this.pino.trace(data ?? {}, msg);
  }

  /**
   * Log at debug level
   */
  debug(msg: string, data?: Record<string, unknown>): void {
    this.pino.debug(data ?? {}, msg);
  }

  /**
   * Log at info level
   */
  info(msg: string, data?: Record<string, unknown>): void {
    this.pino.info(data ?? {}, msg);
  }

  /**
   * Log at warn level
   */
  warn(msg: string, data?: Record<string, unknown>): void {
    this.pino.warn(data ?? {}, msg);
  }

  /**
   * Log at error level
   */
  error(msg: string, error?: Error | Record<string, unknown>): void {
    if (error instanceof Error) {
      this.pino.error({ err: error }, msg);
    } else {
      this.pino.error(error ?? {}, msg);
    }
  }

  /**
   * Log at fatal level
   */
  fatal(msg: string, error?: Error | Record<string, unknown>): void {
    if (error instanceof Error) {
      this.pino.fatal({ err: error }, msg);
    } else {
      this.pino.fatal(error ?? {}, msg);
    }
  }

  /**
   * Start a timer for performance tracking
   */
  startTimer(label: string): () => void {
    const start = performance.now();
    return () => {
      const duration = performance.now() - start;
      this.debug(`${label} completed`, { durationMs: duration.toFixed(2) });
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
      this.pino[level]({ durationMs: duration.toFixed(2) }, `${label} completed`);
      return result;
    } catch (error) {
      const duration = performance.now() - start;
      this.error(`${label} failed`, {
        durationMs: duration.toFixed(2),
        err: error instanceof Error ? error : new Error(String(error)),
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
