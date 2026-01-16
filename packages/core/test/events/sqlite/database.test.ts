/**
 * @fileoverview Tests for Database Connection Management
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection, DEFAULT_CONFIG } from '../../../src/events/sqlite/database.js';

describe('DatabaseConnection', () => {
  let connection: DatabaseConnection;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
  });

  afterEach(() => {
    connection.close();
  });

  describe('constructor', () => {
    it('should create connection with default config', () => {
      const config = connection.getConfig();
      expect(config.dbPath).toBe(':memory:');
      expect(config.enableWAL).toBe(DEFAULT_CONFIG.enableWAL);
      expect(config.busyTimeout).toBe(DEFAULT_CONFIG.busyTimeout);
      expect(config.cacheSize).toBe(DEFAULT_CONFIG.cacheSize);
    });

    it('should accept custom config', () => {
      const customConnection = new DatabaseConnection(':memory:', {
        enableWAL: false,
        busyTimeout: 10000,
        cacheSize: 128000,
      });

      const config = customConnection.getConfig();
      expect(config.enableWAL).toBe(false);
      expect(config.busyTimeout).toBe(10000);
      expect(config.cacheSize).toBe(128000);

      customConnection.close();
    });
  });

  describe('open', () => {
    it('should open database connection', () => {
      const db = connection.open();
      expect(db).toBeDefined();
      expect(connection.isOpen()).toBe(true);
    });

    it('should return same database on multiple calls', () => {
      const db1 = connection.open();
      const db2 = connection.open();
      expect(db1).toBe(db2);
    });

    it('should configure pragmas on open', () => {
      const db = connection.open();

      // Note: In-memory databases can't use WAL mode (SQLite limitation)
      // The journal_mode will remain 'memory' for in-memory databases
      const journalMode = db.pragma('journal_mode', { simple: true });
      expect(['wal', 'memory']).toContain(journalMode);

      // Check foreign keys enabled
      const foreignKeys = db.pragma('foreign_keys', { simple: true });
      expect(foreignKeys).toBe(1);

      // Check synchronous mode
      const synchronous = db.pragma('synchronous', { simple: true });
      expect(synchronous).toBe(1); // NORMAL = 1
    });

    it('should not enable WAL when disabled in config', () => {
      const noWalConnection = new DatabaseConnection(':memory:', { enableWAL: false });
      const db = noWalConnection.open();

      // In-memory databases use 'memory' journal mode regardless of WAL setting
      const journalMode = db.pragma('journal_mode', { simple: true });
      expect(journalMode).toBe('memory');

      noWalConnection.close();
    });
  });

  describe('close', () => {
    it('should close database connection', () => {
      connection.open();
      expect(connection.isOpen()).toBe(true);

      connection.close();
      expect(connection.isOpen()).toBe(false);
      expect(connection.isInitialized()).toBe(false);
    });

    it('should handle close when not open', () => {
      expect(() => connection.close()).not.toThrow();
    });

    it('should reset initialized state on close', () => {
      connection.open();
      connection.markInitialized();
      expect(connection.isInitialized()).toBe(true);

      connection.close();
      expect(connection.isInitialized()).toBe(false);
    });
  });

  describe('getDatabase', () => {
    it('should return database when open', () => {
      connection.open();
      const db = connection.getDatabase();
      expect(db).toBeDefined();
    });

    it('should throw when database not initialized', () => {
      expect(() => connection.getDatabase()).toThrow('Database not initialized');
    });
  });

  describe('markInitialized', () => {
    it('should mark database as initialized', () => {
      connection.open();
      expect(connection.isInitialized()).toBe(false);

      connection.markInitialized();
      expect(connection.isInitialized()).toBe(true);
    });
  });

  describe('getPath', () => {
    it('should return database path', () => {
      expect(connection.getPath()).toBe(':memory:');
    });

    it('should return custom path', () => {
      const customPath = '/tmp/test.db';
      const customConnection = new DatabaseConnection(customPath);
      expect(customConnection.getPath()).toBe(customPath);
      // Don't open to avoid creating file
    });
  });

  describe('transaction', () => {
    it('should execute function within transaction', () => {
      const db = connection.open();

      // Create a test table
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');

      const result = connection.transaction(() => {
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test1');
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test2');
        return db.prepare('SELECT COUNT(*) as count FROM test').get() as { count: number };
      });

      expect(result.count).toBe(2);
    });

    it('should rollback on error', () => {
      const db = connection.open();
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT UNIQUE)');

      db.prepare('INSERT INTO test (value) VALUES (?)').run('existing');

      expect(() => {
        connection.transaction(() => {
          db.prepare('INSERT INTO test (value) VALUES (?)').run('new');
          db.prepare('INSERT INTO test (value) VALUES (?)').run('existing'); // Duplicate!
        });
      }).toThrow();

      // Should have rolled back - only 'existing' remains
      const count = db.prepare('SELECT COUNT(*) as count FROM test').get() as { count: number };
      expect(count.count).toBe(1);
    });
  });

  describe('transactionAsync', () => {
    it('should execute async function within transaction', async () => {
      const db = connection.open();
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');

      const result = await connection.transactionAsync(async () => {
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test1');
        // Simulate async operation
        await Promise.resolve();
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test2');
        return db.prepare('SELECT COUNT(*) as count FROM test').get() as { count: number };
      });

      expect(result.count).toBe(2);
    });

    it('should rollback on async error', async () => {
      const db = connection.open();
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');

      await expect(connection.transactionAsync(async () => {
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test1');
        await Promise.resolve();
        throw new Error('Async failure');
      })).rejects.toThrow('Async failure');

      // Should have rolled back
      const count = db.prepare('SELECT COUNT(*) as count FROM test').get() as { count: number };
      expect(count.count).toBe(0);
    });

    it('should handle nested async transaction (already in transaction)', async () => {
      const db = connection.open();
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');

      // Start outer transaction
      db.exec('BEGIN IMMEDIATE');

      // Inner transactionAsync should not start new transaction
      const result = await connection.transactionAsync(async () => {
        db.prepare('INSERT INTO test (value) VALUES (?)').run('test1');
        return 'success';
      });

      expect(result).toBe('success');

      db.exec('COMMIT');

      const count = db.prepare('SELECT COUNT(*) as count FROM test').get() as { count: number };
      expect(count.count).toBe(1);
    });
  });
});
