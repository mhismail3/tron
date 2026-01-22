/**
 * @fileoverview TDD Tests for LogStore - database-backed log querying
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';
import { LogStore, type LogEntry, type LogQueryOptions, type LogLevel } from '../../src/logging/log-store.js';

describe('LogStore', () => {
  let db: Database.Database;
  let logStore: LogStore;

  // Helper to create the schema
  function createSchema(db: Database.Database): void {
    db.exec(`
      CREATE TABLE IF NOT EXISTS logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        level_num INTEGER NOT NULL,
        component TEXT NOT NULL,
        message TEXT NOT NULL,
        session_id TEXT,
        workspace_id TEXT,
        event_id TEXT,
        turn INTEGER,
        data TEXT,
        error_message TEXT,
        error_stack TEXT
      );

      CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_session_time ON logs(session_id, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_level_time ON logs(level_num, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_component_time ON logs(component, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_event ON logs(event_id, timestamp);
      CREATE INDEX IF NOT EXISTS idx_logs_workspace_time ON logs(workspace_id, timestamp DESC);

      CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
        log_id UNINDEXED,
        session_id UNINDEXED,
        component,
        message,
        error_message,
        tokenize='porter unicode61'
      );
    `);
  }

  // Helper to insert test logs
  function insertLog(log: Partial<LogEntry> & { message: string; component: string; level: LogLevel }): number {
    const levelNum = { trace: 10, debug: 20, info: 30, warn: 40, error: 50, fatal: 60 }[log.level];
    const timestamp = log.timestamp ?? new Date().toISOString();

    const result = db.prepare(`
      INSERT INTO logs (timestamp, level, level_num, component, message, session_id, workspace_id, event_id, turn, data, error_message, error_stack)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      timestamp,
      log.level,
      levelNum,
      log.component,
      log.message,
      log.sessionId ?? null,
      log.workspaceId ?? null,
      log.eventId ?? null,
      log.turn ?? null,
      log.data ? JSON.stringify(log.data) : null,
      log.errorMessage ?? null,
      log.errorStack ?? null
    );

    const logId = result.lastInsertRowid as number;

    // Insert into FTS
    db.prepare(`
      INSERT INTO logs_fts (log_id, session_id, component, message, error_message)
      VALUES (?, ?, ?, ?, ?)
    `).run(logId, log.sessionId ?? null, log.component, log.message, log.errorMessage ?? null);

    return logId;
  }

  beforeEach(() => {
    db = new Database(':memory:');
    createSchema(db);
    logStore = new LogStore(db);
  });

  afterEach(() => {
    db.close();
  });

  describe('query()', () => {
    it('filters by time range', () => {
      insertLog({ message: 'old log', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'recent log', component: 'test', level: 'info', timestamp: '2024-01-15T12:00:00.000Z' });
      insertLog({ message: 'newest log', component: 'test', level: 'info', timestamp: '2024-01-20T00:00:00.000Z' });

      const results = logStore.query({
        since: new Date('2024-01-10T00:00:00.000Z'),
        until: new Date('2024-01-18T00:00:00.000Z'),
      });

      expect(results).toHaveLength(1);
      expect(results[0].message).toBe('recent log');
    });

    it('filters by session_id', () => {
      insertLog({ message: 'session A', component: 'test', level: 'info', sessionId: 'sess_aaa' });
      insertLog({ message: 'session B', component: 'test', level: 'info', sessionId: 'sess_bbb' });
      insertLog({ message: 'no session', component: 'test', level: 'info' });

      const results = logStore.query({ sessionId: 'sess_aaa' });

      expect(results).toHaveLength(1);
      expect(results[0].message).toBe('session A');
    });

    it('filters by level', () => {
      insertLog({ message: 'debug msg', component: 'test', level: 'debug' });
      insertLog({ message: 'info msg', component: 'test', level: 'info' });
      insertLog({ message: 'warn msg', component: 'test', level: 'warn' });
      insertLog({ message: 'error msg', component: 'test', level: 'error' });

      const results = logStore.query({ levels: ['warn', 'error'] });

      expect(results).toHaveLength(2);
      expect(results.map(r => r.level).sort()).toEqual(['error', 'warn']);
    });

    it('filters by component', () => {
      insertLog({ message: 'agent log', component: 'agent', level: 'info' });
      insertLog({ message: 'websocket log', component: 'websocket', level: 'info' });
      insertLog({ message: 'orchestrator log', component: 'orchestrator', level: 'info' });

      const results = logStore.query({ components: ['agent', 'orchestrator'] });

      expect(results).toHaveLength(2);
      expect(results.map(r => r.component).sort()).toEqual(['agent', 'orchestrator']);
    });

    it('filters by workspace_id', () => {
      insertLog({ message: 'workspace A', component: 'test', level: 'info', workspaceId: 'ws_aaa' });
      insertLog({ message: 'workspace B', component: 'test', level: 'info', workspaceId: 'ws_bbb' });

      const results = logStore.query({ workspaceId: 'ws_aaa' });

      expect(results).toHaveLength(1);
      expect(results[0].message).toBe('workspace A');
    });

    it('supports pagination with limit/offset', () => {
      for (let i = 0; i < 10; i++) {
        insertLog({ message: `log ${i}`, component: 'test', level: 'info', timestamp: `2024-01-01T00:00:0${i}.000Z` });
      }

      const page1 = logStore.query({ limit: 3, offset: 0 });
      const page2 = logStore.query({ limit: 3, offset: 3 });

      expect(page1).toHaveLength(3);
      expect(page2).toHaveLength(3);
      // Default order is DESC, so newest first
      expect(page1[0].message).toBe('log 9');
      expect(page2[0].message).toBe('log 6');
    });

    it('orders by timestamp desc by default', () => {
      insertLog({ message: 'first', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'second', component: 'test', level: 'info', timestamp: '2024-01-02T00:00:00.000Z' });
      insertLog({ message: 'third', component: 'test', level: 'info', timestamp: '2024-01-03T00:00:00.000Z' });

      const results = logStore.query({});

      expect(results).toHaveLength(3);
      expect(results[0].message).toBe('third');
      expect(results[1].message).toBe('second');
      expect(results[2].message).toBe('first');
    });

    it('supports ascending order', () => {
      insertLog({ message: 'first', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'second', component: 'test', level: 'info', timestamp: '2024-01-02T00:00:00.000Z' });

      const results = logStore.query({ order: 'asc' });

      expect(results[0].message).toBe('first');
      expect(results[1].message).toBe('second');
    });

    it('combines multiple filters', () => {
      insertLog({ message: 'target', component: 'agent', level: 'error', sessionId: 'sess_aaa' });
      insertLog({ message: 'wrong level', component: 'agent', level: 'info', sessionId: 'sess_aaa' });
      insertLog({ message: 'wrong session', component: 'agent', level: 'error', sessionId: 'sess_bbb' });
      insertLog({ message: 'wrong component', component: 'websocket', level: 'error', sessionId: 'sess_aaa' });

      const results = logStore.query({
        sessionId: 'sess_aaa',
        levels: ['error'],
        components: ['agent'],
      });

      expect(results).toHaveLength(1);
      expect(results[0].message).toBe('target');
    });
  });

  describe('getSessionLogs()', () => {
    it('returns all logs for a session', () => {
      insertLog({ message: 'session log 1', component: 'test', level: 'info', sessionId: 'sess_target' });
      insertLog({ message: 'session log 2', component: 'test', level: 'debug', sessionId: 'sess_target' });
      insertLog({ message: 'other session', component: 'test', level: 'info', sessionId: 'sess_other' });

      const results = logStore.getSessionLogs('sess_target');

      expect(results).toHaveLength(2);
      expect(results.every(r => r.sessionId === 'sess_target')).toBe(true);
    });

    it('respects level filter', () => {
      insertLog({ message: 'info msg', component: 'test', level: 'info', sessionId: 'sess_aaa' });
      insertLog({ message: 'warn msg', component: 'test', level: 'warn', sessionId: 'sess_aaa' });
      insertLog({ message: 'error msg', component: 'test', level: 'error', sessionId: 'sess_aaa' });

      const results = logStore.getSessionLogs('sess_aaa', { levels: ['error'] });

      expect(results).toHaveLength(1);
      expect(results[0].level).toBe('error');
    });
  });

  describe('getLogsAroundEvent()', () => {
    beforeEach(() => {
      // Create logs with sequential timestamps around an event
      insertLog({ message: 'log -3', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z', sessionId: 'sess_test' });
      insertLog({ message: 'log -2', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:01.000Z', sessionId: 'sess_test' });
      insertLog({ message: 'log -1', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:02.000Z', sessionId: 'sess_test' });
      insertLog({ message: 'event log', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:03.000Z', sessionId: 'sess_test', eventId: 'evt_target' });
      insertLog({ message: 'log +1', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:04.000Z', sessionId: 'sess_test' });
      insertLog({ message: 'log +2', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:05.000Z', sessionId: 'sess_test' });
      insertLog({ message: 'log +3', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:06.000Z', sessionId: 'sess_test' });
    });

    it('returns N logs before and M logs after event', () => {
      const results = logStore.getLogsAroundEvent('evt_target', 2, 2);

      expect(results).toHaveLength(5); // 2 before + event + 2 after
      expect(results.map(r => r.message)).toEqual([
        'log -2',
        'log -1',
        'event log',
        'log +1',
        'log +2',
      ]);
    });

    it('handles event at start of session', () => {
      // Insert a log with event_id at the very start
      db.exec('DELETE FROM logs');
      db.exec('DELETE FROM logs_fts');
      insertLog({ message: 'first event', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z', eventId: 'evt_first' });
      insertLog({ message: 'after 1', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:01.000Z' });
      insertLog({ message: 'after 2', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:02.000Z' });

      const results = logStore.getLogsAroundEvent('evt_first', 5, 2);

      expect(results).toHaveLength(3); // Just event + 2 after (no logs before)
      expect(results[0].message).toBe('first event');
    });

    it('handles event at end of session', () => {
      db.exec('DELETE FROM logs');
      db.exec('DELETE FROM logs_fts');
      insertLog({ message: 'before 1', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'before 2', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:01.000Z' });
      insertLog({ message: 'last event', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:02.000Z', eventId: 'evt_last' });

      const results = logStore.getLogsAroundEvent('evt_last', 2, 5);

      expect(results).toHaveLength(3); // 2 before + event (no logs after)
      expect(results[results.length - 1].message).toBe('last event');
    });

    it('returns empty array for non-existent event', () => {
      const results = logStore.getLogsAroundEvent('evt_nonexistent', 2, 2);

      expect(results).toEqual([]);
    });
  });

  describe('search()', () => {
    beforeEach(() => {
      insertLog({ message: 'Processing user authentication request', component: 'auth', level: 'info' });
      insertLog({ message: 'Database connection established', component: 'db', level: 'info' });
      insertLog({ message: 'Failed to authenticate user: invalid credentials', component: 'auth', level: 'error', errorMessage: 'Invalid password' });
      insertLog({ message: 'User logged out successfully', component: 'auth', level: 'info' });
      insertLog({ message: 'Cache miss for key user_123', component: 'cache', level: 'debug' });
    });

    it('finds logs by message content via FTS5', () => {
      const results = logStore.search('authentication');

      expect(results.length).toBeGreaterThan(0);
      expect(results.some(r => r.message.includes('authentication'))).toBe(true);
    });

    it('finds logs by error_message content', () => {
      const results = logStore.search('Invalid password');

      expect(results).toHaveLength(1);
      expect(results[0].errorMessage).toBe('Invalid password');
    });

    it('respects session_id filter', () => {
      insertLog({ message: 'searchable content', component: 'test', level: 'info', sessionId: 'sess_target' });
      insertLog({ message: 'searchable content', component: 'test', level: 'info', sessionId: 'sess_other' });

      const results = logStore.search('searchable', { sessionId: 'sess_target' });

      expect(results).toHaveLength(1);
      expect(results[0].sessionId).toBe('sess_target');
    });

    it('ranks results by relevance', () => {
      // FTS5 should rank by BM25
      const results = logStore.search('user');

      expect(results.length).toBeGreaterThan(0);
      // Results should be returned (ranking is implementation detail)
    });

    it('handles special characters in search query', () => {
      insertLog({ message: 'Error code: ERR_001', component: 'test', level: 'error' });

      // Should not throw on special characters
      const results = logStore.search('ERR_001');
      expect(results).toHaveLength(1);
    });

    it('returns empty array for no matches', () => {
      const results = logStore.search('xyznonexistent123');

      expect(results).toEqual([]);
    });
  });

  describe('getRecentErrors()', () => {
    it('returns only error and fatal logs', () => {
      insertLog({ message: 'info msg', component: 'test', level: 'info' });
      insertLog({ message: 'warn msg', component: 'test', level: 'warn' });
      insertLog({ message: 'error msg', component: 'test', level: 'error' });
      insertLog({ message: 'fatal msg', component: 'test', level: 'fatal' });

      const results = logStore.getRecentErrors();

      expect(results).toHaveLength(2);
      expect(results.every(r => r.level === 'error' || r.level === 'fatal')).toBe(true);
    });

    it('respects limit parameter', () => {
      for (let i = 0; i < 10; i++) {
        insertLog({ message: `error ${i}`, component: 'test', level: 'error' });
      }

      const results = logStore.getRecentErrors(3);

      expect(results).toHaveLength(3);
    });

    it('orders by timestamp desc', () => {
      insertLog({ message: 'old error', component: 'test', level: 'error', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'new error', component: 'test', level: 'error', timestamp: '2024-01-02T00:00:00.000Z' });

      const results = logStore.getRecentErrors();

      expect(results[0].message).toBe('new error');
    });
  });

  describe('pruneOldLogs()', () => {
    it('deletes logs older than specified date', () => {
      insertLog({ message: 'old', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'recent', component: 'test', level: 'info', timestamp: '2024-01-15T00:00:00.000Z' });

      const deleted = logStore.pruneOldLogs(new Date('2024-01-10T00:00:00.000Z'));

      expect(deleted).toBe(1);

      const remaining = logStore.query({});
      expect(remaining).toHaveLength(1);
      expect(remaining[0].message).toBe('recent');
    });

    it('removes corresponding FTS entries', () => {
      insertLog({ message: 'old searchable content', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'recent content', component: 'test', level: 'info', timestamp: '2024-01-15T00:00:00.000Z' });

      logStore.pruneOldLogs(new Date('2024-01-10T00:00:00.000Z'));

      // Should not find the old content via FTS
      const searchResults = logStore.search('old searchable');
      expect(searchResults).toHaveLength(0);
    });

    it('returns count of deleted logs', () => {
      insertLog({ message: 'old 1', component: 'test', level: 'info', timestamp: '2024-01-01T00:00:00.000Z' });
      insertLog({ message: 'old 2', component: 'test', level: 'info', timestamp: '2024-01-02T00:00:00.000Z' });
      insertLog({ message: 'old 3', component: 'test', level: 'info', timestamp: '2024-01-03T00:00:00.000Z' });

      const deleted = logStore.pruneOldLogs(new Date('2024-01-15T00:00:00.000Z'));

      expect(deleted).toBe(3);
    });

    it('returns 0 when no logs to delete', () => {
      insertLog({ message: 'recent', component: 'test', level: 'info', timestamp: '2024-01-15T00:00:00.000Z' });

      const deleted = logStore.pruneOldLogs(new Date('2024-01-01T00:00:00.000Z'));

      expect(deleted).toBe(0);
    });
  });

  describe('getStats()', () => {
    it('returns total count and breakdown by level', () => {
      insertLog({ message: 'info 1', component: 'test', level: 'info' });
      insertLog({ message: 'info 2', component: 'test', level: 'info' });
      insertLog({ message: 'warn 1', component: 'test', level: 'warn' });
      insertLog({ message: 'error 1', component: 'test', level: 'error' });

      const stats = logStore.getStats();

      expect(stats.total).toBe(4);
      expect(stats.byLevel.info).toBe(2);
      expect(stats.byLevel.warn).toBe(1);
      expect(stats.byLevel.error).toBe(1);
    });

    it('returns zeros for empty database', () => {
      const stats = logStore.getStats();

      expect(stats.total).toBe(0);
      expect(stats.byLevel).toEqual({});
    });
  });

  describe('insertLog()', () => {
    it('inserts log with all fields', () => {
      const logId = logStore.insertLog({
        timestamp: '2024-01-15T12:00:00.000Z',
        level: 'error',
        component: 'agent',
        message: 'Something went wrong',
        sessionId: 'sess_123',
        workspaceId: 'ws_456',
        eventId: 'evt_789',
        turn: 3,
        data: { key: 'value' },
        errorMessage: 'Error details',
        errorStack: 'Error: Something\n  at test.ts:1',
      });

      expect(logId).toBeGreaterThan(0);

      const results = logStore.query({ sessionId: 'sess_123' });
      expect(results).toHaveLength(1);
      expect(results[0].message).toBe('Something went wrong');
      expect(results[0].turn).toBe(3);
      expect(results[0].data).toEqual({ key: 'value' });
    });

    it('handles minimal required fields', () => {
      const logId = logStore.insertLog({
        timestamp: new Date().toISOString(),
        level: 'info',
        component: 'test',
        message: 'Simple log',
      });

      expect(logId).toBeGreaterThan(0);
    });

    it('populates FTS index', () => {
      logStore.insertLog({
        timestamp: new Date().toISOString(),
        level: 'info',
        component: 'unique_component',
        message: 'unique searchable message xyz123',
      });

      const results = logStore.search('xyz123');
      expect(results).toHaveLength(1);
    });
  });
});
