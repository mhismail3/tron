/**
 * @fileoverview Integration tests for the logging system
 *
 * Verifies end-to-end functionality:
 * - Logs from createLogger() appear in database
 * - Context propagation works correctly
 * - FTS search works on new logs
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';
import {
  createLogger,
  resetLogger,
  initializeLogTransport,
  closeLogTransport,
  flushLogs,
  withLoggingContext,
  LogStore,
} from '../index.js';

describe('Logging Integration', () => {
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

  beforeEach(() => {
    db = new Database(':memory:');
    createSchema(db);
    logStore = new LogStore(db);

    // Initialize the transport
    initializeLogTransport(db, { minLevel: 10, batchSize: 1 }); // trace and above, immediate flush

    // Reset the singleton logger
    resetLogger();
  });

  afterEach(async () => {
    await flushLogs();
    closeLogTransport();
    resetLogger();
    db.close();
  });

  it('logs from createLogger() appear in database', async () => {
    const logger = createLogger('test-component');

    logger.info('Test integration message');
    await flushLogs();

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].message).toBe('Test integration message');
    expect(logs[0].component).toBe('test-component');
  });

  it('session context propagates to logs', async () => {
    const logger = createLogger('agent');

    await withLoggingContext({ sessionId: 'sess_integration_test' }, async () => {
      logger.info('Log within session context');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].sessionId).toBe('sess_integration_test');
  });

  it('turn context propagates to logs', async () => {
    const logger = createLogger('orchestrator');

    await withLoggingContext({ sessionId: 'sess_turn_test', turn: 5 }, async () => {
      logger.info('Processing turn');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].turn).toBe(5);
  });

  it('event_id context propagates to logs', async () => {
    const logger = createLogger('event-processor');

    await withLoggingContext({ eventId: 'evt_12345' }, async () => {
      logger.debug('Processing event');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    expect(logs[0].eventId).toBe('evt_12345');
  });

  it('logs are searchable via FTS immediately', async () => {
    const logger = createLogger('searchable');

    logger.info('Unique searchable content xyz789');
    await flushLogs();

    const results = logStore.search('xyz789');
    expect(results).toHaveLength(1);
    expect(results[0].message).toContain('xyz789');
  });

  it('existing logger.info() calls still work', async () => {
    const logger = createLogger('basic');

    // All these call signatures should work
    logger.info('Simple message');
    logger.info('Message with data', { key: 'value' });
    logger.info({ key: 'value' }, 'Data first message');

    await flushLogs();

    const logs = logStore.query({});
    expect(logs).toHaveLength(3);
  });

  it('nested contexts work correctly', async () => {
    const logger = createLogger('nested');

    await withLoggingContext({ sessionId: 'sess_outer' }, async () => {
      logger.info('Outer context log');
      await flushLogs(); // Flush immediately to capture outer context
      await new Promise(resolve => setTimeout(resolve, 10)); // Ensure distinct timestamps

      await withLoggingContext({ turn: 1, eventId: 'evt_inner' }, async () => {
        logger.info('Inner context log');
        await flushLogs();
      });
    });

    const logs = logStore.query({ order: 'asc' });
    expect(logs).toHaveLength(2);

    // Find logs by message to avoid ordering issues
    const outerLog = logs.find(l => l.message === 'Outer context log');
    const innerLog = logs.find(l => l.message === 'Inner context log');

    expect(outerLog).toBeDefined();
    expect(innerLog).toBeDefined();

    // Outer log has only session
    expect(outerLog!.sessionId).toBe('sess_outer');
    expect(outerLog!.turn).toBeUndefined();

    // Inner log has session (inherited) + turn + eventId
    expect(innerLog!.sessionId).toBe('sess_outer');
    expect(innerLog!.turn).toBe(1);
    expect(innerLog!.eventId).toBe('evt_inner');
  });

  it('error logs capture error details', async () => {
    const logger = createLogger('error-test');
    const testError = new Error('Integration test error');

    logger.error('An error occurred', testError);
    await flushLogs();

    const logs = logStore.getRecentErrors();
    expect(logs).toHaveLength(1);
    expect(logs[0].errorMessage).toBe('Integration test error');
    expect(logs[0].errorStack).toContain('Error: Integration test error');
  });

  it('multiple components are tracked separately', async () => {
    const agentLogger = createLogger('agent');
    const wsLogger = createLogger('websocket');
    const toolLogger = createLogger('bash-tool');

    agentLogger.info('Agent log');
    wsLogger.info('WebSocket log');
    toolLogger.info('Tool log');

    await flushLogs();

    const agentLogs = logStore.query({ components: ['agent'] });
    const wsLogs = logStore.query({ components: ['websocket'] });
    const allLogs = logStore.query({});

    expect(agentLogs).toHaveLength(1);
    expect(wsLogs).toHaveLength(1);
    expect(allLogs).toHaveLength(3);
  });

  it('time-range queries work with real timestamps', async () => {
    const logger = createLogger('time-test');

    logger.info('First log');
    await new Promise(resolve => setTimeout(resolve, 50));
    const midTime = new Date();
    await new Promise(resolve => setTimeout(resolve, 50));
    logger.info('Second log');

    await flushLogs();

    const recentLogs = logStore.query({ since: midTime });
    expect(recentLogs).toHaveLength(1);
    expect(recentLogs[0].message).toBe('Second log');
  });

  it('handles high volume logging without losing logs', async () => {
    const logger = createLogger('volume-test');

    for (let i = 0; i < 100; i++) {
      logger.info(`Log message ${i}`);
    }

    await flushLogs();

    const logs = logStore.query({});
    expect(logs).toHaveLength(100);
  });

  it('child loggers inherit and merge context', async () => {
    const parentLogger = createLogger('parent', { sessionId: 'sess_parent' });
    const childLogger = parentLogger.child({ toolName: 'read' });

    await withLoggingContext({ turn: 3 }, async () => {
      childLogger.info('Child logger message');
      await flushLogs();
    });

    const logs = logStore.query({});
    expect(logs).toHaveLength(1);
    // Should have component from parent, turn from context
    expect(logs[0].component).toBe('parent');
    expect(logs[0].turn).toBe(3);
  });
});
