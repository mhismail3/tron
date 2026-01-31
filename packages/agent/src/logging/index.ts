/**
 * @fileoverview Logging exports
 */

export {
  TronLogger,
  getLogger,
  createLogger,
  resetLogger,
  initializeLogTransport,
  closeLogTransport,
  flushLogs,
  type LogLevel,
  type LoggerOptions,
  type LogContext,
} from './logger.js';

export {
  withLoggingContext,
  getLoggingContext,
  updateLoggingContext,
  setLoggingContext,
  clearLoggingContext,
  type LoggingContext,
} from './log-context.js';

export {
  LogStore,
  type LogEntry,
  type LogQueryOptions,
  type InsertLogOptions,
  type LogStats,
  type LogLevel as LogStoreLevel,
} from './log-store.js';

export {
  SQLiteTransport,
  type SQLiteTransportOptions,
  type PinoLogObject,
} from './sqlite-transport.js';

export {
  LoggerRegistry,
  getDefaultRegistry,
  setDefaultRegistry,
  resetDefaultRegistry,
  type LoggerRegistryOptions,
  type TransportOptions,
} from './logger-registry.js';

export {
  LogErrorCategory,
  LogErrorCodes,
  categorizeError,
  createStructuredError,
  type StructuredError,
  type LogErrorCode,
} from './error-codes.js';

export {
  OperationLogger,
  createOperationLogger,
  type OperationLoggerOptions,
} from './operation-logger.js';

// Export interfaces for dependency injection
export type {
  ITronLogger,
  ILoggerRegistry,
  ITransport,
} from './types.js';

export { LOG_LEVEL_NUM } from './types.js';
