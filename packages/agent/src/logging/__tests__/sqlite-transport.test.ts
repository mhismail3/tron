/**
 * @fileoverview TDD Tests for SQLite Transport - Pino transport that writes to SQLite
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import Database from 'better-sqlite3';
import { SQLiteTransport, type SQLiteTransportOptions } from '../sqlite-transport.js';
import { setLoggingContext, clearLoggingContext } from '../log-context.js';

describe('SQLiteTransport', () => {
  let db: Database.Database;
  let transport: SQLiteTransport;

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

  function getLogCount(): number {
    return (db.prepare('SELECT COUNT(*) as count FROM logs').get() as { count: number }).count;
  }

  function getLastLog(): any {
    return db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get();
  }

  function getAllLogs(): any[] {
    return db.prepare('SELECT * FROM logs ORDER BY id ASC').all();
  }

  beforeEach(() => {
    db = new Database(':memory:');
    createSchema(db);
    clearLoggingContext();
  });

  afterEach(() => {
    transport?.close();
    db.close();
    clearLoggingContext();
  });

  describe('write()', () => {
    beforeEach(() => {
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100 });
    });

    it('inserts log entry to database', async () => {
      await transport.write({
        level: 30, // info
        time: Date.now(),
        msg: 'Test message',
        component: 'test',
      });

      await transport.flush();

      expect(getLogCount()).toBe(1);
      const log = getLastLog();
      expect(log.message).toBe('Test message');
      expect(log.level).toBe('info');
      expect(log.component).toBe('test');
    });

    it('populates FTS index', async () => {
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Searchable unique content xyz',
        component: 'test',
      });

      await transport.flush();

      const ftsResult = db.prepare(`
        SELECT * FROM logs_fts WHERE logs_fts MATCH '"xyz"'
      `).all();

      expect(ftsResult).toHaveLength(1);
    });

    it('extracts session context from AsyncLocalStorage', async () => {
      setLoggingContext({
        sessionId: 'sess_from_context',
        workspaceId: 'ws_from_context',
        eventId: 'evt_from_context',
        turn: 5,
      });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Message with context',
        component: 'test',
      });

      await transport.flush();

      const log = getLastLog();
      expect(log.session_id).toBe('sess_from_context');
      expect(log.workspace_id).toBe('ws_from_context');
      expect(log.event_id).toBe('evt_from_context');
      expect(log.turn).toBe(5);
    });

    it('serializes data field as JSON', async () => {
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Message with data',
        component: 'test',
        customField: 'value',
        numericField: 42,
        nestedField: { a: 1, b: 2 },
      });

      await transport.flush();

      const log = getLastLog();
      const data = JSON.parse(log.data);
      expect(data.customField).toBe('value');
      expect(data.numericField).toBe(42);
      expect(data.nestedField).toEqual({ a: 1, b: 2 });
    });

    it('extracts error info from err object', async () => {
      const testError = new Error('Test error message');
      testError.stack = 'Error: Test error message\n  at test.ts:1';

      await transport.write({
        level: 50, // error
        time: Date.now(),
        msg: 'An error occurred',
        component: 'test',
        err: testError,
      });

      await transport.flush();

      const log = getLastLog();
      expect(log.error_message).toBe('Test error message');
      expect(log.error_stack).toContain('Error: Test error message');
    });

    it('handles all log levels correctly', async () => {
      const levels = [
        { num: 10, name: 'trace' },
        { num: 20, name: 'debug' },
        { num: 30, name: 'info' },
        { num: 40, name: 'warn' },
        { num: 50, name: 'error' },
        { num: 60, name: 'fatal' },
      ];

      for (const { num, name } of levels) {
        await transport.write({
          level: num,
          time: Date.now(),
          msg: `${name} message`,
          component: 'test',
        });
      }

      await transport.flush();

      const logs = getAllLogs();
      expect(logs).toHaveLength(6);
      expect(logs.map(l => l.level)).toEqual(['trace', 'debug', 'info', 'warn', 'error', 'fatal']);
    });

    it('respects minLevel filter', async () => {
      transport.close();
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100, minLevel: 30 });

      await transport.write({ level: 10, time: Date.now(), msg: 'trace', component: 'test' }); // trace - filtered
      await transport.write({ level: 20, time: Date.now(), msg: 'debug', component: 'test' }); // debug - filtered
      await transport.write({ level: 30, time: Date.now(), msg: 'info', component: 'test' });  // info - stored
      await transport.write({ level: 40, time: Date.now(), msg: 'warn', component: 'test' });  // warn - stored

      await transport.flush();

      const logs = getAllLogs();
      expect(logs).toHaveLength(2);
      expect(logs.map(l => l.level)).toEqual(['info', 'warn']);
    });
  });

  describe('batching', () => {
    it('batches writes up to batchSize', async () => {
      transport = new SQLiteTransport(db, { batchSize: 5, flushIntervalMs: 10000 });

      // Write 4 logs - should not flush yet
      for (let i = 0; i < 4; i++) {
        await transport.write({
          level: 30,
          time: Date.now(),
          msg: `Log ${i}`,
          component: 'test',
        });
      }

      // Should not be written yet (batch not full)
      expect(getLogCount()).toBe(0);

      // Write one more to hit batch size
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Log 4',
        component: 'test',
      });

      // Small delay for async flush
      await new Promise(resolve => setTimeout(resolve, 10));

      // Should have flushed now
      expect(getLogCount()).toBe(5);
    });

    it('flushes after flushInterval', async () => {
      transport = new SQLiteTransport(db, { batchSize: 100, flushIntervalMs: 50 });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Test message',
        component: 'test',
      });

      // Not flushed immediately
      expect(getLogCount()).toBe(0);

      // Wait for flush interval
      await new Promise(resolve => setTimeout(resolve, 100));

      // Should have flushed
      expect(getLogCount()).toBe(1);
    });

    it('flushes immediately on warn/error/fatal for reliability', async () => {
      transport = new SQLiteTransport(db, { batchSize: 100, flushIntervalMs: 10000 });

      // Write an info log - should not flush
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Info message',
        component: 'test',
      });

      expect(getLogCount()).toBe(0);

      // Write a warn log - should flush immediately (level >= 40)
      await transport.write({
        level: 40, // warn
        time: Date.now(),
        msg: 'Warning message',
        component: 'test',
      });

      // Small delay for async
      await new Promise(resolve => setTimeout(resolve, 10));

      // Both should be flushed (warn triggers immediate flush)
      expect(getLogCount()).toBe(2);

      // Write an error log - should also flush immediately
      await transport.write({
        level: 50, // error
        time: Date.now(),
        msg: 'Error message',
        component: 'test',
      });

      await new Promise(resolve => setTimeout(resolve, 10));
      expect(getLogCount()).toBe(3);
    });

    it('flushes on close', async () => {
      transport = new SQLiteTransport(db, { batchSize: 100, flushIntervalMs: 10000 });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Pending message',
        component: 'test',
      });

      expect(getLogCount()).toBe(0);

      transport.close();

      // Should have flushed on close
      expect(getLogCount()).toBe(1);
    });
  });

  describe('resilience', () => {
    it('does not throw on DB write failure', async () => {
      // Close the database to simulate failure
      const brokenDb = new Database(':memory:');
      // Don't create schema - writes will fail

      const brokenTransport = new SQLiteTransport(brokenDb, { batchSize: 1, flushIntervalMs: 100 });

      // Should not throw
      await expect(
        brokenTransport.write({
          level: 30,
          time: Date.now(),
          msg: 'This will fail',
          component: 'test',
        })
      ).resolves.not.toThrow();

      // Force flush - should not throw
      await expect(brokenTransport.flush()).resolves.not.toThrow();

      brokenTransport.close();
      brokenDb.close();
    });

    it('logs to stderr on DB failure', async () => {
      const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

      // Create transport with broken DB (no schema)
      const brokenDb = new Database(':memory:');
      const brokenTransport = new SQLiteTransport(brokenDb, { batchSize: 1, flushIntervalMs: 100 });

      await brokenTransport.write({
        level: 30,
        time: Date.now(),
        msg: 'This will fail',
        component: 'test',
      });

      await brokenTransport.flush();

      expect(consoleSpy).toHaveBeenCalled();

      consoleSpy.mockRestore();
      brokenTransport.close();
      brokenDb.close();
    });

    it('continues working after transient failure', async () => {
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100 });

      // Simulate transient failure by dropping and recreating table
      const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

      // First write succeeds
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'First message',
        component: 'test',
      });
      await transport.flush();
      expect(getLogCount()).toBe(1);

      // Drop tables to simulate failure
      db.exec('DROP TABLE logs_fts');
      db.exec('DROP TABLE logs');

      // Second write fails silently
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Failed message',
        component: 'test',
      });
      await transport.flush();

      // Recreate tables
      createSchema(db);

      // Third write should succeed
      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Recovery message',
        component: 'test',
      });
      await transport.flush();

      expect(getLogCount()).toBe(1); // Only the recovery message
      expect(getLastLog().message).toBe('Recovery message');

      consoleSpy.mockRestore();
    });

    it('handles null/undefined values gracefully', async () => {
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100 });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Message with nulls',
        component: 'test',
        nullField: null,
        undefinedField: undefined,
      });

      await transport.flush();

      expect(getLogCount()).toBe(1);
    });

    it('handles very large messages', async () => {
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100 });

      const largeMessage = 'x'.repeat(100000);

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: largeMessage,
        component: 'test',
      });

      await transport.flush();

      expect(getLogCount()).toBe(1);
      expect(getLastLog().message).toBe(largeMessage);
    });
  });

  describe('context merging', () => {
    beforeEach(() => {
      transport = new SQLiteTransport(db, { batchSize: 1, flushIntervalMs: 100 });
    });

    it('prefers explicit log fields over context', async () => {
      setLoggingContext({
        sessionId: 'context_session',
        turn: 1,
      });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Message with explicit session',
        component: 'test',
        sessionId: 'explicit_session', // Should override context
      });

      await transport.flush();

      const log = getLastLog();
      expect(log.session_id).toBe('explicit_session');
    });

    it('uses context when log fields are missing', async () => {
      setLoggingContext({
        sessionId: 'context_session',
        workspaceId: 'context_workspace',
      });

      await transport.write({
        level: 30,
        time: Date.now(),
        msg: 'Message without explicit session',
        component: 'test',
      });

      await transport.flush();

      const log = getLastLog();
      expect(log.session_id).toBe('context_session');
      expect(log.workspace_id).toBe('context_workspace');
    });
  });
});
