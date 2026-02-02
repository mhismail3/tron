/**
 * @fileoverview Logging Type Definitions
 *
 * Shared types for the logging module. Extracted to break circular
 * dependencies between logger.ts and logger-registry.ts.
 */

// =============================================================================
// Log Levels
// =============================================================================

export type LogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal';

/** Log level to numeric value mapping */
export const LOG_LEVEL_NUM: Record<LogLevel, number> = {
  trace: 10,
  debug: 20,
  info: 30,
  warn: 40,
  error: 50,
  fatal: 60,
};

// =============================================================================
// Logger Options
// =============================================================================

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
// Registry Options
// =============================================================================

export interface LoggerRegistryOptions {
  /** Default log level for all loggers */
  level?: LogLevel;
  /** Enable pretty printing */
  pretty?: boolean;
}

// =============================================================================
// Transport Options
// =============================================================================

export interface TransportOptions {
  /** Minimum level to persist (default: 30/info) */
  minLevel?: number;
  /** Batch size for writes */
  batchSize?: number;
  /** Flush interval in milliseconds */
  flushIntervalMs?: number;
}

// =============================================================================
// Logger Interface
// =============================================================================

/**
 * Interface for TronLogger to avoid circular dependency.
 * The actual implementation is in logger.ts.
 */
export interface ITronLogger {
  trace(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void;
  debug(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void;
  info(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void;
  warn(msgOrData: string | Record<string, unknown>, msgOrDataSecond?: string | Record<string, unknown>): void;
  error(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void;
  fatal(msgOrData: string | Record<string, unknown>, msgOrDataOrError?: string | Error | Record<string, unknown>): void;
  child(context: LogContext): ITronLogger;
  startTimer(label: string): () => void;
  timed<T>(label: string, fn: () => Promise<T>, level?: LogLevel): Promise<T>;
}

// =============================================================================
// Registry Interface
// =============================================================================

/**
 * Interface for LoggerRegistry to avoid circular dependency.
 * Used by TronLogger to access the transport without importing the class.
 */
export interface ILoggerRegistry {
  getTransport(): ITransport | null;
}

/**
 * Interface for SQLiteTransport to avoid circular dependency.
 */
export interface ITransport {
  write(entry: Record<string, unknown>): Promise<void>;
  flush(): Promise<void>;
  close(): void;
}
