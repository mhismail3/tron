/**
 * @fileoverview SQLite Transport - Pino transport that writes logs to SQLite
 *
 * Features:
 * - Batched writes for performance
 * - Resilient (never throws, falls back to stderr)
 * - Automatic context injection from AsyncLocalStorage
 * - FTS5 indexing for full-text search
 */

import type Database from 'better-sqlite3';
import { getLoggingContext } from './log-context.js';

// =============================================================================
// Types
// =============================================================================

export interface SQLiteTransportOptions {
  /** Number of logs to batch before flushing (default: 50) */
  batchSize?: number;
  /** Milliseconds between flushes (default: 500) */
  flushIntervalMs?: number;
  /** Minimum log level to store (10=trace, 20=debug, 30=info, 40=warn, 50=error, 60=fatal). Default: 10 */
  minLevel?: number;
}

export interface PinoLogObject {
  level: number;
  time: number;
  msg?: string;
  component?: string;
  sessionId?: string;
  workspaceId?: string;
  eventId?: string;
  turn?: number;
  err?: Error | { message?: string; stack?: string };
  [key: string]: unknown;
}

interface LogEntry {
  timestamp: string;
  level: string;
  levelNum: number;
  component: string;
  message: string;
  sessionId: string | null;
  workspaceId: string | null;
  eventId: string | null;
  turn: number | null;
  data: string | null;
  errorMessage: string | null;
  errorStack: string | null;
}

// =============================================================================
// Constants
// =============================================================================

const LEVEL_NAMES: Record<number, string> = {
  10: 'trace',
  20: 'debug',
  30: 'info',
  40: 'warn',
  50: 'error',
  60: 'fatal',
};

// Standard pino fields to exclude from data
const STANDARD_FIELDS = new Set([
  'level', 'time', 'msg', 'component', 'sessionId', 'workspaceId',
  'eventId', 'turn', 'err', 'pid', 'hostname', 'name', 'v',
]);

// =============================================================================
// SQLite Transport Implementation
// =============================================================================

export class SQLiteTransport {
  private db: Database.Database;
  private batch: LogEntry[] = [];
  private batchSize: number;
  private flushIntervalMs: number;
  private minLevel: number;
  private flushTimer: ReturnType<typeof setInterval> | null = null;
  private insertLogStmt: Database.Statement | null = null;
  private insertFtsStmt: Database.Statement | null = null;
  private closed = false;

  constructor(db: Database.Database, options: SQLiteTransportOptions = {}) {
    this.db = db;
    this.batchSize = options.batchSize ?? 50;
    this.flushIntervalMs = options.flushIntervalMs ?? 500;
    this.minLevel = options.minLevel ?? 10;

    this.prepareStatements();
    this.startFlushTimer();
  }

  private prepareStatements(): void {
    try {
      this.insertLogStmt = this.db.prepare(`
        INSERT INTO logs (timestamp, level, level_num, component, message, session_id, workspace_id, event_id, turn, data, error_message, error_stack)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);

      this.insertFtsStmt = this.db.prepare(`
        INSERT INTO logs_fts (log_id, session_id, component, message, error_message)
        VALUES (?, ?, ?, ?, ?)
      `);
    } catch {
      // Tables may not exist - will retry on first write
      this.insertLogStmt = null;
      this.insertFtsStmt = null;
    }
  }

  private startFlushTimer(): void {
    this.flushTimer = setInterval(() => {
      this.flush().catch(() => {
        // Ignore errors in timer
      });
    }, this.flushIntervalMs);

    // Don't block process exit
    if (this.flushTimer.unref) {
      this.flushTimer.unref();
    }
  }

  /**
   * Write a log entry to the batch
   */
  async write(logObj: PinoLogObject): Promise<void> {
    try {
      // Filter by level
      if (logObj.level < this.minLevel) {
        return;
      }

      const entry = this.transformLog(logObj);
      this.batch.push(entry);

      // Flush immediately on warn/error/fatal for reliability
      // This ensures important logs are persisted immediately
      if (logObj.level >= 40) {
        await this.flush();
      } else if (this.batch.length >= this.batchSize) {
        await this.flush();
      }
    } catch (error) {
      // NEVER throw - log to stderr instead
      console.error('[LOG_TRANSPORT_WRITE_ERROR]', error);
    }
  }

  /**
   * Flush pending logs to database
   */
  async flush(): Promise<void> {
    if (this.batch.length === 0) return;

    const toFlush = this.batch;
    this.batch = [];

    try {
      // Prepare statements if needed
      if (!this.insertLogStmt || !this.insertFtsStmt) {
        this.prepareStatements();
      }

      if (!this.insertLogStmt || !this.insertFtsStmt) {
        throw new Error('Failed to prepare statements - tables may not exist');
      }

      // Execute in a transaction for atomicity and performance
      this.db.transaction(() => {
        for (const entry of toFlush) {
          const result = this.insertLogStmt!.run(
            entry.timestamp,
            entry.level,
            entry.levelNum,
            entry.component,
            entry.message,
            entry.sessionId,
            entry.workspaceId,
            entry.eventId,
            entry.turn,
            entry.data,
            entry.errorMessage,
            entry.errorStack
          );

          const logId = result.lastInsertRowid as number;

          this.insertFtsStmt!.run(
            logId,
            entry.sessionId,
            entry.component,
            entry.message,
            entry.errorMessage
          );
        }
      })();
    } catch (error) {
      // Log to stderr, don't rethrow
      console.error('[LOG_FLUSH_ERROR]', error, `Lost ${toFlush.length} logs`);
    }
  }

  /**
   * Close the transport, flushing any pending logs
   */
  close(): void {
    if (this.closed) return;
    this.closed = true;

    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }

    // Synchronous flush on close
    try {
      if (this.batch.length > 0 && this.insertLogStmt && this.insertFtsStmt) {
        this.db.transaction(() => {
          for (const entry of this.batch) {
            const result = this.insertLogStmt!.run(
              entry.timestamp,
              entry.level,
              entry.levelNum,
              entry.component,
              entry.message,
              entry.sessionId,
              entry.workspaceId,
              entry.eventId,
              entry.turn,
              entry.data,
              entry.errorMessage,
              entry.errorStack
            );

            const logId = result.lastInsertRowid as number;

            this.insertFtsStmt!.run(
              logId,
              entry.sessionId,
              entry.component,
              entry.message,
              entry.errorMessage
            );
          }
        })();
      }
    } catch {
      // Ignore close errors
    }

    this.batch = [];
  }

  /**
   * Transform a pino log object into our internal format
   */
  private transformLog(logObj: PinoLogObject): LogEntry {
    // Get context from AsyncLocalStorage
    const context = getLoggingContext();

    // Extract error info
    let errorMessage: string | null = null;
    let errorStack: string | null = null;
    if (logObj.err) {
      if (logObj.err instanceof Error) {
        errorMessage = logObj.err.message;
        errorStack = logObj.err.stack ?? null;
      } else if (typeof logObj.err === 'object') {
        errorMessage = logObj.err.message ?? null;
        errorStack = logObj.err.stack ?? null;
      }
    }

    // Extract additional data fields (exclude standard fields)
    const data: Record<string, unknown> = {};
    let hasData = false;
    for (const [key, value] of Object.entries(logObj)) {
      if (!STANDARD_FIELDS.has(key) && value !== undefined && value !== null) {
        data[key] = value;
        hasData = true;
      }
    }

    // Prefer explicit log fields over context
    const sessionId = logObj.sessionId ?? context.sessionId ?? null;
    const workspaceId = logObj.workspaceId ?? context.workspaceId ?? null;
    const eventId = logObj.eventId ?? context.eventId ?? null;
    const turn = logObj.turn ?? context.turn ?? null;

    return {
      timestamp: new Date(logObj.time).toISOString(),
      level: LEVEL_NAMES[logObj.level] ?? 'info',
      levelNum: logObj.level,
      component: logObj.component ?? 'unknown',
      message: logObj.msg ?? '',
      sessionId,
      workspaceId,
      eventId,
      turn,
      data: hasData ? JSON.stringify(data) : null,
      errorMessage,
      errorStack,
    };
  }
}
