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
   * Log at trace level
   * Supports: (msg), (msg, data), and (data, msg) signatures
   */
  trace(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void {
    if (typeof msgOrData === 'string') {
      if (typeof msgOrDataSecond === 'object') {
        this.pino.trace(msgOrDataSecond, msgOrData);
      } else {
        this.pino.trace(msgOrData);
      }
    } else {
      this.pino.trace(msgOrData, typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '');
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
      } else {
        this.pino.debug(msgOrData);
      }
    } else {
      this.pino.debug(msgOrData, typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '');
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
      } else {
        this.pino.info(msgOrData);
      }
    } else {
      this.pino.info(msgOrData, typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '');
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
      } else {
        this.pino.warn(msgOrData);
      }
    } else {
      this.pino.warn(msgOrData, typeof msgOrDataSecond === 'string' ? msgOrDataSecond : '');
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
      } else if (typeof msgOrDataOrError === 'object') {
        this.pino.error(msgOrDataOrError, msgOrData);
      } else {
        this.pino.error(msgOrData);
      }
    } else {
      this.pino.error(msgOrData, typeof msgOrDataOrError === 'string' ? msgOrDataOrError : '');
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
      } else if (typeof msgOrDataOrError === 'object') {
        this.pino.fatal(msgOrDataOrError, msgOrData);
      } else {
        this.pino.fatal(msgOrData);
      }
    } else {
      this.pino.fatal(msgOrData, typeof msgOrDataOrError === 'string' ? msgOrDataOrError : '');
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
