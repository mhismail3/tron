/**
 * @fileoverview Tests for v005 Migration - Trace ID Columns
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Database } from 'bun:sqlite';
import { runMigrations } from '../index.js';

describe('v005 migration - trace columns', () => {
  let db: Database;

  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  afterEach(() => {
    db.close();
  });

  describe('column creation', () => {
    it('should add trace_id column to logs table', () => {
      const columns = db
        .prepare("PRAGMA table_info(logs)")
        .all() as { name: string }[];

      const hasTraceId = columns.some(c => c.name === 'trace_id');
      expect(hasTraceId).toBe(true);
    });

    it('should add parent_trace_id column to logs table', () => {
      const columns = db
        .prepare("PRAGMA table_info(logs)")
        .all() as { name: string }[];

      const hasParentTraceId = columns.some(c => c.name === 'parent_trace_id');
      expect(hasParentTraceId).toBe(true);
    });

    it('should add depth column to logs table with default 0', () => {
      const columns = db
        .prepare("PRAGMA table_info(logs)")
        .all() as { name: string; dflt_value: string | null }[];

      const depthCol = columns.find(c => c.name === 'depth');
      expect(depthCol).toBeDefined();
      expect(depthCol?.dflt_value).toBe('0');
    });
  });

  describe('index creation', () => {
    it('should create idx_logs_trace_id index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_logs_trace_id'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });

    it('should create idx_logs_parent_trace index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_logs_parent_trace'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });
  });

  describe('functionality', () => {
    it('should store and retrieve trace_id values', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message, trace_id)
         VALUES (datetime('now'), 'info', 30, 'test', 'test message', 'trace-123')`
      ).run();

      const log = db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get() as {
        trace_id: string;
      };
      expect(log.trace_id).toBe('trace-123');
    });

    it('should store and retrieve parent_trace_id values', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message, trace_id, parent_trace_id)
         VALUES (datetime('now'), 'info', 30, 'test', 'test message', 'child-trace', 'parent-trace')`
      ).run();

      const log = db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get() as {
        parent_trace_id: string;
      };
      expect(log.parent_trace_id).toBe('parent-trace');
    });

    it('should store and retrieve depth values', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message, depth)
         VALUES (datetime('now'), 'info', 30, 'test', 'test message', 3)`
      ).run();

      const log = db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get() as {
        depth: number;
      };
      expect(log.depth).toBe(3);
    });

    it('should default depth to 0 when not provided', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (datetime('now'), 'info', 30, 'test', 'test message')`
      ).run();

      const log = db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get() as {
        depth: number;
      };
      expect(log.depth).toBe(0);
    });

    it('should allow null trace_id', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (datetime('now'), 'info', 30, 'test', 'no trace')`
      ).run();

      const log = db.prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 1').get() as {
        trace_id: string | null;
      };
      expect(log.trace_id).toBeNull();
    });
  });

  describe('index usage', () => {
    it('should use trace_id index for trace queries', () => {
      const plan = db
        .prepare("EXPLAIN QUERY PLAN SELECT * FROM logs WHERE trace_id = 'test-trace'")
        .all() as { detail: string }[];
      const usesIndex = plan.some((p) => p.detail?.includes('idx_logs_trace_id'));
      expect(usesIndex).toBe(true);
    });

    it('should use parent_trace_id index for child queries', () => {
      const plan = db
        .prepare("EXPLAIN QUERY PLAN SELECT * FROM logs WHERE parent_trace_id = 'parent-trace'")
        .all() as { detail: string }[];
      const usesIndex = plan.some((p) => p.detail?.includes('idx_logs_parent_trace'));
      expect(usesIndex).toBe(true);
    });
  });

  describe('idempotency', () => {
    it('can run migration multiple times without error', () => {
      // Running migrations again should not fail
      expect(() => runMigrations(db)).not.toThrow();

      // Schema should still be intact
      const columns = db
        .prepare("PRAGMA table_info(logs)")
        .all() as { name: string }[];

      const hasTraceId = columns.some(c => c.name === 'trace_id');
      expect(hasTraceId).toBe(true);
    });
  });
});
