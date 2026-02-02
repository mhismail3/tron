/**
 * @fileoverview Tests for LoggerRegistry
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Database from 'better-sqlite3';
import {
  LoggerRegistry,
  getDefaultRegistry,
  setDefaultRegistry,
  resetDefaultRegistry,
} from '../logger-registry.js';
import { TronLogger } from '../logger.js';

function createLogsSchema(db: Database.Database): void {
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

describe('LoggerRegistry', () => {
  let registry: LoggerRegistry;

  beforeEach(() => {
    registry = new LoggerRegistry();
  });

  afterEach(() => {
    registry.close();
  });

  describe('constructor', () => {
    it('should create a new registry with default options', () => {
      expect(registry).toBeInstanceOf(LoggerRegistry);
      expect(registry.isClosed()).toBe(false);
      expect(registry.hasTransport()).toBe(false);
    });

    it('should accept custom options', () => {
      const customRegistry = new LoggerRegistry({ level: 'debug', pretty: true });
      expect(customRegistry).toBeInstanceOf(LoggerRegistry);
      customRegistry.close();
    });
  });

  describe('getLogger', () => {
    it('should return a TronLogger instance', () => {
      const logger = registry.getLogger();
      expect(logger).toBeInstanceOf(TronLogger);
    });

    it('should return the same logger instance on subsequent calls', () => {
      const logger1 = registry.getLogger();
      const logger2 = registry.getLogger();
      expect(logger1).toBe(logger2);
    });

    it('should throw if registry is closed', () => {
      registry.close();
      expect(() => registry.getLogger()).toThrow('LoggerRegistry has been closed');
    });
  });

  describe('createLogger', () => {
    it('should create a child logger with component context', () => {
      const logger = registry.createLogger('test-component');
      expect(logger).toBeInstanceOf(TronLogger);
    });

    it('should create child logger with additional context', () => {
      const logger = registry.createLogger('agent', { sessionId: 'sess_123' });
      expect(logger).toBeInstanceOf(TronLogger);
    });
  });

  describe('initializeTransport', () => {
    let db: Database.Database;

    beforeEach(() => {
      db = new Database(':memory:');
      createLogsSchema(db);
    });

    afterEach(() => {
      db.close();
    });

    it('should initialize SQLite transport', () => {
      registry.initializeTransport(db);
      expect(registry.hasTransport()).toBe(true);
    });

    it('should accept custom transport options', () => {
      registry.initializeTransport(db, {
        minLevel: 40, // warn and above
        batchSize: 50,
        flushIntervalMs: 2000,
      });
      expect(registry.hasTransport()).toBe(true);
    });

    it('should replace existing transport on reinitialization', () => {
      registry.initializeTransport(db);
      const transport1 = registry.getTransport();
      registry.initializeTransport(db);
      const transport2 = registry.getTransport();

      expect(transport1).not.toBe(transport2);
    });

    it('should throw if registry is closed', () => {
      registry.close();
      expect(() => registry.initializeTransport(db)).toThrow('LoggerRegistry has been closed');
    });
  });

  describe('flush', () => {
    let db: Database.Database;

    beforeEach(() => {
      db = new Database(':memory:');
      createLogsSchema(db);
    });

    afterEach(() => {
      db.close();
    });

    it('should not throw if no transport is initialized', async () => {
      await expect(registry.flush()).resolves.toBeUndefined();
    });

    it('should flush transport when initialized', async () => {
      registry.initializeTransport(db);
      await expect(registry.flush()).resolves.toBeUndefined();
    });
  });

  describe('close', () => {
    it('should mark registry as closed', () => {
      registry.close();
      expect(registry.isClosed()).toBe(true);
    });

    it('should be idempotent', () => {
      registry.close();
      registry.close(); // Should not throw
      expect(registry.isClosed()).toBe(true);
    });

    it('should close transport if initialized', () => {
      const db = new Database(':memory:');
      createLogsSchema(db);
      registry.initializeTransport(db);

      registry.close();
      expect(registry.hasTransport()).toBe(false);
      db.close();
    });
  });

  describe('reset', () => {
    it('should reset registry to initial state', () => {
      const db = new Database(':memory:');
      createLogsSchema(db);
      registry.initializeTransport(db);
      registry.getLogger(); // Create root logger

      registry.reset();

      expect(registry.hasTransport()).toBe(false);
      expect(registry.isClosed()).toBe(false);
      db.close();
    });

    it('should allow reuse after reset', () => {
      registry.close();
      registry.reset();

      const logger = registry.getLogger();
      expect(logger).toBeInstanceOf(TronLogger);
    });
  });

  describe('multiple registries', () => {
    it('should maintain independent state', () => {
      const registry1 = new LoggerRegistry({ level: 'debug' });
      const registry2 = new LoggerRegistry({ level: 'info' });

      const logger1 = registry1.getLogger();
      const logger2 = registry2.getLogger();

      expect(logger1).not.toBe(logger2);

      registry1.close();
      registry2.close();
    });

    it('should have independent transports', () => {
      const db1 = new Database(':memory:');
      const db2 = new Database(':memory:');
      createLogsSchema(db1);
      createLogsSchema(db2);

      const registry1 = new LoggerRegistry();
      const registry2 = new LoggerRegistry();

      registry1.initializeTransport(db1);
      registry2.initializeTransport(db2);

      expect(registry1.getTransport()).not.toBe(registry2.getTransport());

      registry1.close();
      registry2.close();
      db1.close();
      db2.close();
    });
  });
});

describe('Default Registry Functions', () => {
  beforeEach(() => {
    resetDefaultRegistry();
  });

  afterEach(() => {
    resetDefaultRegistry();
  });

  describe('getDefaultRegistry', () => {
    it('should return a LoggerRegistry instance', () => {
      const registry = getDefaultRegistry();
      expect(registry).toBeInstanceOf(LoggerRegistry);
    });

    it('should return the same instance on subsequent calls', () => {
      const registry1 = getDefaultRegistry();
      const registry2 = getDefaultRegistry();
      expect(registry1).toBe(registry2);
    });
  });

  describe('setDefaultRegistry', () => {
    it('should allow setting a custom default registry', () => {
      const customRegistry = new LoggerRegistry();
      setDefaultRegistry(customRegistry);

      expect(getDefaultRegistry()).toBe(customRegistry);
      customRegistry.close();
    });

    it('should allow setting to null', () => {
      getDefaultRegistry(); // Ensure one exists
      setDefaultRegistry(null);

      // Should create a new one
      const registry = getDefaultRegistry();
      expect(registry).toBeInstanceOf(LoggerRegistry);
    });
  });

  describe('resetDefaultRegistry', () => {
    it('should reset and clear the default registry', () => {
      const registry1 = getDefaultRegistry();
      resetDefaultRegistry();
      const registry2 = getDefaultRegistry();

      expect(registry1).not.toBe(registry2);
    });
  });
});
