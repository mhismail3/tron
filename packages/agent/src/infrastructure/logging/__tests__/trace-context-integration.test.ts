/**
 * @fileoverview Integration tests for trace context propagation
 *
 * Verifies that traceId, parentTraceId, and depth propagate correctly
 * through the AsyncLocalStorage context to SQLite logs.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';
import { randomUUID } from 'crypto';
import {
  createLogger,
  resetLogger,
  initializeLogTransport,
  closeLogTransport,
  flushLogs,
  withLoggingContext,
  updateLoggingContext,
  clearLoggingContext,
  LogStore,
} from '../index.js';

describe('Trace context integration', () => {
  let db: Database.Database;
  let logStore: LogStore;

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
        trace_id TEXT,
        parent_trace_id TEXT,
        depth INTEGER DEFAULT 0,
        data TEXT,
        error_message TEXT,
        error_stack TEXT
      );

      CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);
      CREATE INDEX IF NOT EXISTS idx_logs_parent_trace ON logs(parent_trace_id);

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

  beforeEach(() => {
    db = new Database(':memory:');
    createSchema(db);
    logStore = new LogStore(db);

    // Initialize transport with immediate flush
    initializeLogTransport(db, { minLevel: 10, batchSize: 1 });
    resetLogger();
    clearLoggingContext();
  });

  afterEach(async () => {
    await flushLogs();
    closeLogTransport();
    resetLogger();
    clearLoggingContext();
    db.close();
  });

  it('logs have traceId when context is set', async () => {
    const logger = createLogger('test');
    const traceId = randomUUID();

    await withLoggingContext({ traceId, depth: 0 }, async () => {
      logger.info('Test message with trace');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].traceId).toBe(traceId);
    expect(logs[0].depth).toBe(0);
  });

  it('logs have no traceId when context is not set', async () => {
    const logger = createLogger('test');

    logger.info('Test message without trace');
    await flushLogs();

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    // traceId can be null or undefined when not set
    expect(logs[0].traceId).toBeFalsy();
  });

  it('nested context creates parent-child trace relationship', async () => {
    const logger = createLogger('test');
    const parentTraceId = randomUUID();
    const childTraceId = randomUUID();

    await withLoggingContext({ traceId: parentTraceId, depth: 0 }, async () => {
      logger.info('Parent log');
      await flushLogs();

      await withLoggingContext({
        traceId: childTraceId,
        parentTraceId,
        depth: 1,
      }, async () => {
        logger.info('Child log');
        await flushLogs();
      });
    });

    const logs = logStore.query({ order: 'asc' });
    expect(logs).toHaveLength(2);

    // Find logs by message
    const parentLog = logs.find(l => l.message === 'Parent log');
    const childLog = logs.find(l => l.message === 'Child log');

    expect(parentLog).toBeDefined();
    expect(childLog).toBeDefined();

    // Parent has traceId and depth 0
    expect(parentLog!.traceId).toBe(parentTraceId);
    expect(parentLog!.parentTraceId).toBeNull();
    expect(parentLog!.depth).toBe(0);

    // Child has its own traceId, links to parent, and depth 1
    expect(childLog!.traceId).toBe(childTraceId);
    expect(childLog!.parentTraceId).toBe(parentTraceId);
    expect(childLog!.depth).toBe(1);
  });

  it('deeply nested traces have correct depth', async () => {
    const logger = createLogger('test');
    const rootTraceId = randomUUID();
    const level1TraceId = randomUUID();
    const level2TraceId = randomUUID();

    await withLoggingContext({ traceId: rootTraceId, depth: 0 }, async () => {
      logger.info('Root log');
      await flushLogs();

      await withLoggingContext({
        traceId: level1TraceId,
        parentTraceId: rootTraceId,
        depth: 1,
      }, async () => {
        logger.info('Level 1 log');
        await flushLogs();

        await withLoggingContext({
          traceId: level2TraceId,
          parentTraceId: level1TraceId,
          depth: 2,
        }, async () => {
          logger.info('Level 2 log');
          await flushLogs();
        });
      });
    });

    const logs = logStore.query({ order: 'asc' });
    expect(logs).toHaveLength(3);

    const rootLog = logs.find(l => l.message === 'Root log');
    const level1Log = logs.find(l => l.message === 'Level 1 log');
    const level2Log = logs.find(l => l.message === 'Level 2 log');

    expect(rootLog!.depth).toBe(0);
    expect(level1Log!.depth).toBe(1);
    expect(level2Log!.depth).toBe(2);

    // Verify parent chain
    expect(rootLog!.parentTraceId).toBeNull();
    expect(level1Log!.parentTraceId).toBe(rootTraceId);
    expect(level2Log!.parentTraceId).toBe(level1TraceId);
  });

  it('turn number propagates to logs via updateLoggingContext', async () => {
    const logger = createLogger('test');
    const traceId = randomUUID();

    await withLoggingContext({ traceId }, async () => {
      updateLoggingContext({ turn: 3 });
      logger.info('Turn 3 log');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].turn).toBe(3);
    expect(logs[0].traceId).toBe(traceId);
  });

  it('traceId and sessionId coexist correctly', async () => {
    const logger = createLogger('test');
    const sessionId = 'sess_test123';
    const traceId = randomUUID();

    await withLoggingContext({ sessionId, traceId, depth: 0 }, async () => {
      logger.info('Log with session and trace');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].sessionId).toBe(sessionId);
    expect(logs[0].traceId).toBe(traceId);
  });

  it('multiple logs within same trace context share traceId', async () => {
    const logger = createLogger('test');
    const traceId = randomUUID();

    await withLoggingContext({ traceId, depth: 0 }, async () => {
      logger.info('First log');
      logger.info('Second log');
      logger.info('Third log');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(3);
    expect(logs.every(l => l.traceId === traceId)).toBe(true);
  });

  it('sequential withLoggingContext calls have independent traceIds', async () => {
    const logger = createLogger('test');
    const traceId1 = randomUUID();
    const traceId2 = randomUUID();

    await withLoggingContext({ traceId: traceId1 }, async () => {
      logger.info('First run');
      await flushLogs();
    });

    await withLoggingContext({ traceId: traceId2 }, async () => {
      logger.info('Second run');
      await flushLogs();
    });

    const logs = logStore.query({ order: 'asc' });
    expect(logs).toHaveLength(2);

    const firstLog = logs.find(l => l.message === 'First run');
    const secondLog = logs.find(l => l.message === 'Second run');

    expect(firstLog!.traceId).toBe(traceId1);
    expect(secondLog!.traceId).toBe(traceId2);
    expect(firstLog!.traceId).not.toBe(secondLog!.traceId);
  });
});
