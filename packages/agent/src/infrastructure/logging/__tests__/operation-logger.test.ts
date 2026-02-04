/**
 * @fileoverview TDD Tests for OperationLogger - multi-level operation logging utility
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Database } from 'bun:sqlite';
import {
  OperationLogger,
  createOperationLogger,
  type OperationLoggerConfig,
} from '../operation-logger.js';
import { TronLogger, initializeLogTransport, closeLogTransport } from '../logger.js';
import {
  setLoggingContext,
  clearLoggingContext,
  getLoggingContext,
  withLoggingContext,
} from '../log-context.js';

describe('OperationLogger', () => {
  let db: Database.Database;
  let logger: TronLogger;

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

      CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
        log_id UNINDEXED,
        session_id UNINDEXED,
        component,
        message,
        error_message,
        tokenize='porter unicode61'
      );

      CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs(trace_id);
      CREATE INDEX IF NOT EXISTS idx_logs_parent_trace ON logs(parent_trace_id);
    `);
  }

  function getAllLogs(): any[] {
    return db.prepare('SELECT * FROM logs ORDER BY id ASC').all();
  }

  function getLastLog(): any {
    return db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get();
  }

  beforeEach(() => {
    db = new Database(':memory:');
    createSchema(db);
    initializeLogTransport(db, { minLevel: 10, batchSize: 1, flushIntervalMs: 100 });
    logger = new TronLogger({ level: 'trace', pretty: false });
    clearLoggingContext();
  });

  afterEach(() => {
    closeLogTransport();
    db.close();
    clearLoggingContext();
  });

  describe('trace ID generation', () => {
    it('generates unique traceId for each operation', async () => {
      const op1 = createOperationLogger(logger.child({ component: 'test' }), 'operation1');
      const op2 = createOperationLogger(logger.child({ component: 'test' }), 'operation2');

      expect(op1.traceId).toBeTruthy();
      expect(op2.traceId).toBeTruthy();
      expect(op1.traceId).not.toBe(op2.traceId);
    });

    it('traceId is a valid UUID format', () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'test-op');
      const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

      expect(op.traceId).toMatch(uuidRegex);
    });

    it('preserves parent traceId when nested', async () => {
      const parentOp = createOperationLogger(logger.child({ component: 'test' }), 'parent');

      // Create child within parent's context
      const childOp = withLoggingContext({ traceId: parentOp.traceId }, () => {
        return createOperationLogger(logger.child({ component: 'test' }), 'child');
      });

      expect(childOp.parentTraceId).toBe(parentOp.traceId);
    });

    it('updates AsyncLocalStorage context with traceId when autoTrace is true', () => {
      withLoggingContext({}, () => {
        const op = createOperationLogger(logger.child({ component: 'test' }), 'test-op', {
          autoTrace: true,
        });

        const ctx = getLoggingContext();
        expect(ctx.traceId).toBe(op.traceId);
      });
    });

    it('does not update context when autoTrace is false', () => {
      withLoggingContext({ traceId: 'existing-trace' }, () => {
        createOperationLogger(logger.child({ component: 'test' }), 'test-op', {
          autoTrace: false,
        });

        const ctx = getLoggingContext();
        expect(ctx.traceId).toBe('existing-trace');
      });
    });
  });

  describe('multi-level logging', () => {
    it('enriches all log calls with operation context', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'enrichment-test', {
        context: { customKey: 'customValue' },
      });

      op.info('Test message');

      // Force flush
      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.message).toBe('Test message');
      // traceId goes to its own column, not the data JSON
      expect(log.trace_id).toBe(op.traceId);
      const data = JSON.parse(log.data || '{}');
      expect(data.operation).toBe('enrichment-test');
      expect(data.customKey).toBe('customValue');
    });

    it('supports trace level', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'trace-test');
      op.trace('Trace message');

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.level).toBe('trace');
      expect(log.message).toBe('Trace message');
    });

    it('supports debug level', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'debug-test');
      op.debug('Debug message', { debugData: 123 });

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.level).toBe('debug');
      expect(log.message).toBe('Debug message');
      const data = JSON.parse(log.data || '{}');
      expect(data.debugData).toBe(123);
    });

    it('supports info level', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'info-test');
      op.info('Info message');

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.level).toBe('info');
    });

    it('supports warn level', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'warn-test');
      op.warn('Warning message');

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.level).toBe('warn');
    });

    it('supports error level with Error object', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'error-test');
      const testError = new Error('Test error');
      op.error('Error occurred', testError);

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.level).toBe('error');
      expect(log.error_message).toBe('Test error');
    });

    it('includes elapsed time in complete()', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'timing-test');

      // Wait a bit to have measurable elapsed time (15ms with 10ms threshold for timer variance)
      await new Promise((resolve) => setTimeout(resolve, 15));

      op.complete('Operation finished');

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      expect(log.message).toBe('Operation finished');
      const data = JSON.parse(log.data || '{}');
      expect(data.elapsedMs).toBeGreaterThanOrEqual(10);
    });
  });

  describe('context propagation', () => {
    it('merges static context with per-call data', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'merge-test', {
        context: { staticKey: 'staticValue' },
      });

      op.info('Merge test', { dynamicKey: 'dynamicValue' });

      const { flushLogs } = await import('../logger.js');
      await flushLogs();

      const log = getLastLog();
      const data = JSON.parse(log.data || '{}');
      expect(data.staticKey).toBe('staticValue');
      expect(data.dynamicKey).toBe('dynamicValue');
    });

    it('supports nested operations with inherited context', async () => {
      const parentOp = createOperationLogger(logger.child({ component: 'parent' }), 'parent-op', {
        context: { parentKey: 'parentValue' },
      });

      const childOp = parentOp.child('child-op', { childKey: 'childValue' });

      expect(childOp.parentTraceId).toBe(parentOp.traceId);
      expect(childOp.depth).toBe(parentOp.depth + 1);
    });
  });

  describe('sub-agent support', () => {
    it('tracks parentTraceId for nested operations', () => {
      const parentOp = createOperationLogger(logger.child({ component: 'test' }), 'parent');

      withLoggingContext({ traceId: parentOp.traceId, depth: 0 }, () => {
        const childOp = createOperationLogger(logger.child({ component: 'test' }), 'child');

        expect(childOp.parentTraceId).toBe(parentOp.traceId);
      });
    });

    it('tracks depth for nested operations', () => {
      const rootOp = createOperationLogger(logger.child({ component: 'test' }), 'root');
      expect(rootOp.depth).toBe(0);

      withLoggingContext({ traceId: rootOp.traceId, depth: 0 }, () => {
        const level1Op = createOperationLogger(logger.child({ component: 'test' }), 'level1');
        expect(level1Op.depth).toBe(1);

        withLoggingContext({ traceId: level1Op.traceId, depth: 1 }, () => {
          const level2Op = createOperationLogger(logger.child({ component: 'test' }), 'level2');
          expect(level2Op.depth).toBe(2);
        });
      });
    });

    it('allows explicit depth override', () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'custom-depth', {
        depth: 5,
      });

      expect(op.depth).toBe(5);
    });

    it('allows explicit parentTraceId override', () => {
      const explicitParentId = 'explicit-parent-trace-id';
      const op = createOperationLogger(logger.child({ component: 'test' }), 'custom-parent', {
        parentTraceId: explicitParentId,
      });

      expect(op.parentTraceId).toBe(explicitParentId);
    });
  });

  describe('elapsed time tracking', () => {
    it('returns elapsed time via elapsed() method', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'elapsed-test');

      await new Promise((resolve) => setTimeout(resolve, 25));

      const elapsed = op.elapsed();
      // Allow slight variance due to timer resolution
      expect(elapsed).toBeGreaterThanOrEqual(20);
    });

    it('elapsed time continues to increase', async () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'elapsed-test');

      await new Promise((resolve) => setTimeout(resolve, 10));
      const elapsed1 = op.elapsed();

      await new Promise((resolve) => setTimeout(resolve, 10));
      const elapsed2 = op.elapsed();

      expect(elapsed2).toBeGreaterThan(elapsed1);
    });
  });

  describe('createOperationLogger factory', () => {
    it('creates OperationLogger instance', () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'factory-test');

      expect(op).toBeInstanceOf(OperationLogger);
    });

    it('accepts optional context', () => {
      const op = createOperationLogger(logger.child({ component: 'test' }), 'context-test', {
        context: { key: 'value' },
      });

      expect(op).toBeInstanceOf(OperationLogger);
    });
  });
});
