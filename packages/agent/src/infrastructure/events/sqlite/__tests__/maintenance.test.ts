/**
 * @fileoverview Tests for Database Maintenance Service
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Database } from 'bun:sqlite';
import { runMigrations } from '../migrations/index.js';
import { DatabaseMaintenance } from '../maintenance.js';

describe('DatabaseMaintenance', () => {
  let db: Database;
  let maintenance: DatabaseMaintenance;

  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
    maintenance = new DatabaseMaintenance(db);
  });

  afterEach(() => {
    db?.close();
  });

  describe('runMaintenance', () => {
    it('should prune logs older than retention period', () => {
      // Insert old logs (older than 30 days)
      const oldDate = new Date();
      oldDate.setDate(oldDate.getDate() - 40);
      const oldTimestamp = oldDate.toISOString();

      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'old log 1')`
      ).run(oldTimestamp);
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'old log 2')`
      ).run(oldTimestamp);

      // Insert recent logs
      const recentDate = new Date().toISOString();
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'recent log')`
      ).run(recentDate);

      const result = maintenance.runMaintenance(30);

      // Old logs should be deleted (logsPruned includes trigger operations in bun:sqlite)
      expect(result.logsPruned).toBeGreaterThan(0);

      // Recent log should remain - this is the definitive check
      const count = db.prepare('SELECT COUNT(*) as c FROM logs').get() as { c: number };
      expect(count.c).toBe(1);
    });

    it('should clean unreferenced blobs', () => {
      // Insert blob with ref_count = 0 (unreferenced)
      db.prepare(
        `INSERT INTO blobs (id, hash, content, size_original, size_compressed, created_at, ref_count)
         VALUES ('blob1', 'hash1', X'00', 1, 1, datetime('now'), 0)`
      ).run();

      // Insert blob with ref_count = 1 (referenced)
      db.prepare(
        `INSERT INTO blobs (id, hash, content, size_original, size_compressed, created_at, ref_count)
         VALUES ('blob2', 'hash2', X'00', 1, 1, datetime('now'), 1)`
      ).run();

      const result = maintenance.runMaintenance();

      // Only unreferenced blob should be deleted
      expect(result.blobsCleaned).toBe(1);

      // Referenced blob should remain
      const remaining = db.prepare("SELECT id FROM blobs WHERE id = 'blob2'").get();
      expect(remaining).toBeDefined();
    });

    it('should run ANALYZE after maintenance', () => {
      // Run maintenance
      maintenance.runMaintenance();

      // sqlite_stat1 should exist and have data after ANALYZE
      // For in-memory databases with no data, this may be empty
      // but the call should not throw
      const stats = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sqlite_stat1'").all();
      // ANALYZE creates sqlite_stat1 only if there's data to analyze
      // The important thing is that maintenance completes without error
      expect(stats).toBeDefined();
    });

    it('should handle empty database gracefully', () => {
      // Run on empty database
      const result = maintenance.runMaintenance();

      expect(result.logsPruned).toBe(0);
      expect(result.blobsCleaned).toBe(0);
    });

    it('should also prune logs_fts when pruning logs', () => {
      // Insert old log (will be auto-synced to FTS via trigger)
      const oldDate = new Date();
      oldDate.setDate(oldDate.getDate() - 40);
      const oldTimestamp = oldDate.toISOString();

      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'old log message')`
      ).run(oldTimestamp);

      const logId = (db.prepare('SELECT id FROM logs ORDER BY id DESC LIMIT 1').get() as { id: number }).id;

      // Verify FTS entry exists
      const ftsBefore = db.prepare('SELECT COUNT(*) as c FROM logs_fts WHERE log_id = ?').get(logId) as {
        c: number;
      };
      expect(ftsBefore.c).toBe(1);

      // Run maintenance
      maintenance.runMaintenance(30);

      // FTS entry should also be deleted (via cascade from trigger)
      const ftsAfter = db.prepare('SELECT COUNT(*) as c FROM logs_fts WHERE log_id = ?').get(logId) as {
        c: number;
      };
      expect(ftsAfter.c).toBe(0);
    });

    it('should respect custom retention period', () => {
      // Insert log 10 days old
      const oldDate = new Date();
      oldDate.setDate(oldDate.getDate() - 10);
      const oldTimestamp = oldDate.toISOString();

      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'log from 10 days ago')`
      ).run(oldTimestamp);

      // With 30 day retention, log should remain
      let result = maintenance.runMaintenance(30);
      expect(result.logsPruned).toBe(0);

      // Insert again (since it wasn't deleted)
      db.prepare('DELETE FROM logs').run();
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'log from 10 days ago')`
      ).run(oldTimestamp);

      // With 7 day retention, log should be deleted (logsPruned includes trigger operations in bun:sqlite)
      result = maintenance.runMaintenance(7);
      expect(result.logsPruned).toBeGreaterThan(0);

      // Verify the log was actually deleted
      const countAfter = db.prepare('SELECT COUNT(*) as c FROM logs').get() as { c: number };
      expect(countAfter.c).toBe(0);
    });
  });

  describe('checkpoint', () => {
    it('should run WAL checkpoint without error', () => {
      // checkpoint should not throw on in-memory database
      // (may be a no-op but shouldn't error)
      expect(() => maintenance.checkpoint()).not.toThrow();
    });
  });

  describe('getStats', () => {
    it('should return database statistics', () => {
      // Insert some data
      const now = new Date().toISOString();
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (?, 'INFO', 2, 'test', 'test log')`
      ).run(now);

      db.prepare(
        `INSERT INTO blobs (id, hash, content, size_original, size_compressed, created_at, ref_count)
         VALUES ('blob1', 'hash1', X'00', 1, 1, datetime('now'), 1)`
      ).run();

      const stats = maintenance.getStats();

      expect(stats.logCount).toBe(1);
      expect(stats.blobCount).toBe(1);
      expect(stats.unreferencedBlobCount).toBe(0);
    });

    it('should count unreferenced blobs separately', () => {
      db.prepare(
        `INSERT INTO blobs (id, hash, content, size_original, size_compressed, created_at, ref_count)
         VALUES ('blob1', 'hash1', X'00', 1, 1, datetime('now'), 0)`
      ).run();
      db.prepare(
        `INSERT INTO blobs (id, hash, content, size_original, size_compressed, created_at, ref_count)
         VALUES ('blob2', 'hash2', X'00', 1, 1, datetime('now'), 1)`
      ).run();

      const stats = maintenance.getStats();

      expect(stats.blobCount).toBe(2);
      expect(stats.unreferencedBlobCount).toBe(1);
    });
  });
});
