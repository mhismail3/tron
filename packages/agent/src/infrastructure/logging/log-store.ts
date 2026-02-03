/**
 * @fileoverview LogStore - Database-backed log querying API
 *
 * Provides robust querying capabilities for logs stored in SQLite:
 * - Time-range queries
 * - Session-scoped queries
 * - Level and component filtering
 * - Full-text search via FTS5
 * - "Around event" queries for debugging
 */

import type Database from 'better-sqlite3';
import { LOG_LEVEL_NUM, type LogLevel } from './types.js';

// Re-export LogLevel for backward compatibility
export type { LogLevel };

export interface LogEntry {
  id: number;
  timestamp: string;
  level: LogLevel;
  component: string;
  message: string;
  sessionId?: string;
  workspaceId?: string;
  eventId?: string;
  turn?: number;
  traceId?: string;
  parentTraceId?: string | null;
  depth?: number;
  data?: Record<string, unknown>;
  errorMessage?: string;
  errorStack?: string;
}

export interface LogQueryOptions {
  since?: Date;
  until?: Date;
  sessionId?: string;
  workspaceId?: string;
  eventId?: string;
  levels?: LogLevel[];
  components?: string[];
  search?: string;
  limit?: number;
  offset?: number;
  order?: 'asc' | 'desc';
  /** Filter by exact trace ID */
  traceId?: string;
  /** Filter by parent trace ID (find children) */
  parentTraceId?: string | null;
  /** Filter by nesting depth */
  depth?: number;
  /** Minimum log level (numeric: 10=trace, 20=debug, 30=info, 40=warn, 50=error, 60=fatal) */
  minLevel?: number;
}

export interface InsertLogOptions {
  timestamp: string;
  level: LogLevel;
  component: string;
  message: string;
  sessionId?: string;
  workspaceId?: string;
  eventId?: string;
  turn?: number;
  traceId?: string;
  parentTraceId?: string | null;
  depth?: number;
  data?: Record<string, unknown>;
  errorMessage?: string;
  errorStack?: string;
}

export interface LogStats {
  total: number;
  byLevel: Record<string, number>;
}

// =============================================================================
// LogStore Implementation
// =============================================================================

export class LogStore {
  private db: Database.Database;
  private insertLogStmt: Database.Statement | null = null;
  private insertFtsStmt: Database.Statement | null = null;

  constructor(db: Database.Database) {
    this.db = db;
    this.prepareStatements();
  }

  private prepareStatements(): void {
    try {
      this.insertLogStmt = this.db.prepare(`
        INSERT INTO logs (timestamp, level, level_num, component, message, session_id, workspace_id, event_id, turn, trace_id, parent_trace_id, depth, data, error_message, error_stack)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);

      this.insertFtsStmt = this.db.prepare(`
        INSERT INTO logs_fts (log_id, session_id, component, message, error_message)
        VALUES (?, ?, ?, ?, ?)
      `);
    } catch {
      // Tables may not exist yet - statements will be created lazily
      this.insertLogStmt = null;
      this.insertFtsStmt = null;
    }
  }

  /**
   * Insert a log entry into the database
   */
  insertLog(log: InsertLogOptions): number {
    const levelNum = LOG_LEVEL_NUM[log.level];

    // Prepare statements lazily if not already done
    if (!this.insertLogStmt) {
      this.prepareStatements();
    }

    const result = this.insertLogStmt!.run(
      log.timestamp,
      log.level,
      levelNum,
      log.component,
      log.message,
      log.sessionId ?? null,
      log.workspaceId ?? null,
      log.eventId ?? null,
      log.turn ?? null,
      log.traceId ?? null,
      log.parentTraceId ?? null,
      log.depth ?? 0,
      log.data ? JSON.stringify(log.data) : null,
      log.errorMessage ?? null,
      log.errorStack ?? null
    );

    const logId = result.lastInsertRowid as number;

    // Insert into FTS index
    this.insertFtsStmt!.run(
      logId,
      log.sessionId ?? null,
      log.component,
      log.message,
      log.errorMessage ?? null
    );

    return logId;
  }

  /**
   * Query logs with various filters
   */
  query(options: LogQueryOptions): LogEntry[] {
    const conditions: string[] = ['1=1'];
    const params: unknown[] = [];

    if (options.since) {
      conditions.push('timestamp >= ?');
      params.push(options.since.toISOString());
    }

    if (options.until) {
      conditions.push('timestamp <= ?');
      params.push(options.until.toISOString());
    }

    if (options.sessionId) {
      conditions.push('session_id = ?');
      params.push(options.sessionId);
    }

    if (options.workspaceId) {
      conditions.push('workspace_id = ?');
      params.push(options.workspaceId);
    }

    if (options.eventId) {
      conditions.push('event_id = ?');
      params.push(options.eventId);
    }

    if (options.levels && options.levels.length > 0) {
      const placeholders = options.levels.map(() => '?').join(',');
      conditions.push(`level IN (${placeholders})`);
      params.push(...options.levels);
    }

    if (options.components && options.components.length > 0) {
      const placeholders = options.components.map(() => '?').join(',');
      conditions.push(`component IN (${placeholders})`);
      params.push(...options.components);
    }

    if (options.traceId) {
      conditions.push('trace_id = ?');
      params.push(options.traceId);
    }

    if (options.parentTraceId !== undefined) {
      if (options.parentTraceId === null) {
        conditions.push('parent_trace_id IS NULL');
      } else {
        conditions.push('parent_trace_id = ?');
        params.push(options.parentTraceId);
      }
    }

    if (options.depth !== undefined) {
      conditions.push('depth = ?');
      params.push(options.depth);
    }

    if (options.minLevel !== undefined) {
      conditions.push('level_num >= ?');
      params.push(options.minLevel);
    }

    const order = options.order === 'asc' ? 'ASC' : 'DESC';

    let sql = `
      SELECT * FROM logs
      WHERE ${conditions.join(' AND ')}
      ORDER BY timestamp ${order}
    `;

    if (options.limit !== undefined) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options.offset !== undefined) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = this.db.prepare(sql).all(...params) as LogRow[];
    return rows.map(this.rowToLogEntry);
  }

  /**
   * Get all logs for a specific session
   */
  getSessionLogs(sessionId: string, options?: Omit<LogQueryOptions, 'sessionId'>): LogEntry[] {
    return this.query({ ...options, sessionId });
  }

  /**
   * Get logs around a specific event (before and after)
   */
  getLogsAroundEvent(eventId: string, before: number, after: number): LogEntry[] {
    // First, find the event log to get its timestamp
    const eventLog = this.db.prepare(`
      SELECT timestamp, session_id FROM logs WHERE event_id = ? LIMIT 1
    `).get(eventId) as { timestamp: string; session_id: string | null } | undefined;

    if (!eventLog) {
      return [];
    }

    const { timestamp, session_id } = eventLog;

    // Get logs before the event
    const beforeLogs = this.db.prepare(`
      SELECT * FROM logs
      WHERE timestamp < ?
      ${session_id ? 'AND session_id = ?' : ''}
      ORDER BY timestamp DESC
      LIMIT ?
    `).all(...(session_id ? [timestamp, session_id, before] : [timestamp, before])) as LogRow[];

    // Get the event log itself and logs after
    const afterLogs = this.db.prepare(`
      SELECT * FROM logs
      WHERE timestamp >= ?
      ${session_id ? 'AND session_id = ?' : ''}
      ORDER BY timestamp ASC
      LIMIT ?
    `).all(...(session_id ? [timestamp, session_id, after + 1] : [timestamp, after + 1])) as LogRow[];

    // Combine: reverse beforeLogs (to get chronological), then afterLogs
    return [...beforeLogs.reverse(), ...afterLogs].map(this.rowToLogEntry);
  }

  /**
   * Full-text search on log messages using FTS5
   */
  search(queryText: string, options?: Omit<LogQueryOptions, 'search'>): LogEntry[] {
    // Escape special FTS5 characters
    const escapedQuery = this.escapeFtsQuery(queryText);

    const conditions: string[] = ['logs_fts MATCH ?'];
    const params: unknown[] = [escapedQuery];

    if (options?.sessionId) {
      conditions.push('logs.session_id = ?');
      params.push(options.sessionId);
    }

    if (options?.workspaceId) {
      conditions.push('logs.workspace_id = ?');
      params.push(options.workspaceId);
    }

    if (options?.levels && options.levels.length > 0) {
      const placeholders = options.levels.map(() => '?').join(',');
      conditions.push(`logs.level IN (${placeholders})`);
      params.push(...options.levels);
    }

    if (options?.since) {
      conditions.push('logs.timestamp >= ?');
      params.push(options.since.toISOString());
    }

    if (options?.until) {
      conditions.push('logs.timestamp <= ?');
      params.push(options.until.toISOString());
    }

    const order = options?.order === 'asc' ? 'ASC' : 'DESC';
    let limit = options?.limit ?? 100;

    const sql = `
      SELECT logs.*, bm25(logs_fts) as rank
      FROM logs_fts
      JOIN logs ON logs_fts.log_id = logs.id
      WHERE ${conditions.join(' AND ')}
      ORDER BY rank, logs.timestamp ${order}
      LIMIT ?
    `;

    params.push(limit);

    const rows = this.db.prepare(sql).all(...params) as LogRow[];
    return rows.map(this.rowToLogEntry);
  }

  /**
   * Get recent error and fatal logs
   */
  getRecentErrors(limit: number = 50): LogEntry[] {
    return this.query({
      levels: ['error', 'fatal'],
      limit,
      order: 'desc',
    });
  }

  /**
   * Get all logs in a trace tree (root trace and all descendants)
   *
   * This uses a recursive CTE to find all logs that belong to the trace hierarchy.
   */
  getTraceTree(traceId: string): LogEntry[] {
    // Use recursive CTE to find all logs in the trace hierarchy
    const sql = `
      WITH RECURSIVE trace_tree AS (
        -- Base case: logs with the given trace_id
        SELECT trace_id FROM logs WHERE trace_id = ?
        UNION
        -- Recursive case: find children
        SELECT l.trace_id
        FROM logs l
        JOIN trace_tree t ON l.parent_trace_id = t.trace_id
      )
      SELECT DISTINCT logs.*
      FROM logs
      WHERE logs.trace_id IN (SELECT trace_id FROM trace_tree WHERE trace_id IS NOT NULL)
      ORDER BY logs.timestamp ASC
    `;

    const rows = this.db.prepare(sql).all(traceId) as LogRow[];
    return rows.map(this.rowToLogEntry);
  }

  /**
   * Delete logs older than the specified date
   */
  pruneOldLogs(olderThan: Date): number {
    const timestamp = olderThan.toISOString();

    // Get IDs of logs to delete for FTS cleanup
    const idsToDelete = this.db.prepare(`
      SELECT id FROM logs WHERE timestamp < ?
    `).all(timestamp) as { id: number }[];

    if (idsToDelete.length === 0) {
      return 0;
    }

    // Delete from FTS first
    const idPlaceholders = idsToDelete.map(() => '?').join(',');
    this.db.prepare(`
      DELETE FROM logs_fts WHERE log_id IN (${idPlaceholders})
    `).run(...idsToDelete.map(r => r.id));

    // Delete from logs table
    const result = this.db.prepare(`
      DELETE FROM logs WHERE timestamp < ?
    `).run(timestamp);

    return result.changes;
  }

  /**
   * Get statistics about logs
   */
  getStats(): LogStats {
    const total = this.db.prepare(`SELECT COUNT(*) as count FROM logs`).get() as { count: number };

    const byLevelRows = this.db.prepare(`
      SELECT level, COUNT(*) as count FROM logs GROUP BY level
    `).all() as { level: string; count: number }[];

    const byLevel: Record<string, number> = {};
    for (const row of byLevelRows) {
      byLevel[row.level] = row.count;
    }

    return {
      total: total.count,
      byLevel,
    };
  }

  /**
   * Escape special characters for FTS5 queries
   */
  private escapeFtsQuery(query: string): string {
    // FTS5 uses double quotes for phrases and has special operators
    // For safety, wrap tokens in double quotes
    return query
      .split(/\s+/)
      .filter(token => token.length > 0)
      .map(token => `"${token.replace(/"/g, '""')}"`)
      .join(' ');
  }

  private rowToLogEntry(row: LogRow): LogEntry {
    return {
      id: row.id,
      timestamp: row.timestamp,
      level: row.level as LogLevel,
      component: row.component,
      message: row.message,
      sessionId: row.session_id ?? undefined,
      workspaceId: row.workspace_id ?? undefined,
      eventId: row.event_id ?? undefined,
      turn: row.turn ?? undefined,
      traceId: row.trace_id ?? undefined,
      parentTraceId: row.parent_trace_id,
      depth: row.depth ?? undefined,
      data: row.data ? JSON.parse(row.data) : undefined,
      errorMessage: row.error_message ?? undefined,
      errorStack: row.error_stack ?? undefined,
    };
  }
}

// =============================================================================
// Internal Types
// =============================================================================

interface LogRow {
  id: number;
  timestamp: string;
  level: string;
  level_num: number;
  component: string;
  message: string;
  session_id: string | null;
  workspace_id: string | null;
  event_id: string | null;
  turn: number | null;
  trace_id: string | null;
  parent_trace_id: string | null;
  depth: number | null;
  data: string | null;
  error_message: string | null;
  error_stack: string | null;
}
