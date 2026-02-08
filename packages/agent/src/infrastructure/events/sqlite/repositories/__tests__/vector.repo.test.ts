/**
 * @fileoverview Tests for VectorRepository
 *
 * Tests sqlite-vec backed vector storage with real extension.
 * Tests are skipped if sqlite-vec is not available.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createRequire } from 'module';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { VectorRepository } from '../vector.repo.js';

// Try to load sqlite-vec
let sqliteVecPath: string | null = null;
try {
  const require = createRequire(import.meta.url);
  const { getLoadablePath } = require('sqlite-vec');
  sqliteVecPath = getLoadablePath();
} catch {
  // sqlite-vec not available
}

const describeWithVec = sqliteVecPath ? describe : describe.skip;

describeWithVec('VectorRepository', () => {
  let connection: DatabaseConnection;
  let repo: VectorRepository;
  const DIMS = 4; // Small for testing

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);

    // Load sqlite-vec extension
    db.loadExtension(sqliteVecPath!);

    repo = new VectorRepository(connection, DIMS);
    repo.ensureTable();
  });

  afterEach(() => {
    connection.close();
  });

  describe('ensureTable', () => {
    it('creates the memory_vectors virtual table', () => {
      expect(repo.hasTable()).toBe(true);
    });

    it('is idempotent', () => {
      repo.ensureTable(); // second call should not throw
      expect(repo.hasTable()).toBe(true);
    });
  });

  describe('hasTable', () => {
    it('returns false when table does not exist', () => {
      const conn2 = new DatabaseConnection(':memory:');
      const db2 = conn2.open();
      runMigrations(db2);
      db2.loadExtension(sqliteVecPath!);

      const repo2 = new VectorRepository(conn2, DIMS);
      // Don't call ensureTable
      expect(repo2.hasTable()).toBe(false);

      conn2.close();
    });
  });

  describe('store', () => {
    it('stores a vector', () => {
      const embedding = new Float32Array([1, 0, 0, 0]);
      repo.store('evt-1', 'ws-1', embedding);

      expect(repo.count()).toBe(1);
    });

    it('replaces existing vector with same event_id via delete+insert', () => {
      const emb1 = new Float32Array([1, 0, 0, 0]);
      const emb2 = new Float32Array([0, 1, 0, 0]);

      repo.store('evt-1', 'ws-1', emb1);
      repo.delete('evt-1');
      repo.store('evt-1', 'ws-1', emb2);

      expect(repo.count()).toBe(1);

      // Search should find the new vector, not the old one
      const results = repo.search(new Float32Array([0, 1, 0, 0]), { limit: 1 });
      expect(results[0]!.eventId).toBe('evt-1');
      expect(results[0]!.distance).toBeCloseTo(0, 3);
    });

    it('stores multiple vectors', () => {
      repo.store('evt-1', 'ws-1', new Float32Array([1, 0, 0, 0]));
      repo.store('evt-2', 'ws-1', new Float32Array([0, 1, 0, 0]));
      repo.store('evt-3', 'ws-2', new Float32Array([0, 0, 1, 0]));

      expect(repo.count()).toBe(3);
    });
  });

  describe('search', () => {
    beforeEach(() => {
      // Insert test vectors across two workspaces
      repo.store('evt-1', 'ws-1', new Float32Array([1, 0, 0, 0]));
      repo.store('evt-2', 'ws-1', new Float32Array([0.9, 0.1, 0, 0]));
      repo.store('evt-3', 'ws-2', new Float32Array([0, 0, 1, 0]));
      repo.store('evt-4', 'ws-2', new Float32Array([0, 0, 0, 1]));
    });

    it('returns nearest neighbors ordered by distance', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query, { limit: 4 });

      expect(results.length).toBe(4);
      // evt-1 is exact match (distance 0), evt-2 is close
      expect(results[0]!.eventId).toBe('evt-1');
      expect(results[0]!.distance).toBeCloseTo(0, 3);
      expect(results[1]!.eventId).toBe('evt-2');
      // Remaining two should be further away
      expect(results[2]!.distance).toBeGreaterThan(results[1]!.distance);
    });

    it('respects limit parameter', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query, { limit: 2 });

      expect(results.length).toBe(2);
    });

    it('filters by workspaceId', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query, { workspaceId: 'ws-2', limit: 10 });

      expect(results.every(r => r.workspaceId === 'ws-2')).toBe(true);
    });

    it('excludes workspace with excludeWorkspaceId', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query, { excludeWorkspaceId: 'ws-1', limit: 10 });

      expect(results.every(r => r.workspaceId !== 'ws-1')).toBe(true);
      expect(results.length).toBe(2); // Only ws-2 vectors
    });

    it('returns empty array when no vectors match filter', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query, { workspaceId: 'ws-nonexistent', limit: 10 });

      expect(results).toEqual([]);
    });

    it('includes distance in results', () => {
      const query = new Float32Array([1, 0, 0, 0]);
      const results = repo.search(query);

      for (const result of results) {
        expect(typeof result.distance).toBe('number');
        expect(result.distance).toBeGreaterThanOrEqual(0);
      }
    });
  });

  describe('delete', () => {
    it('removes a vector by event_id', () => {
      repo.store('evt-1', 'ws-1', new Float32Array([1, 0, 0, 0]));
      repo.store('evt-2', 'ws-1', new Float32Array([0, 1, 0, 0]));

      expect(repo.count()).toBe(2);

      repo.delete('evt-1');

      expect(repo.count()).toBe(1);
    });

    it('is a no-op for non-existent event_id', () => {
      repo.store('evt-1', 'ws-1', new Float32Array([1, 0, 0, 0]));

      repo.delete('evt-nonexistent'); // should not throw

      expect(repo.count()).toBe(1);
    });
  });

  describe('count', () => {
    it('returns 0 for empty table', () => {
      expect(repo.count()).toBe(0);
    });

    it('returns correct count', () => {
      repo.store('evt-1', 'ws-1', new Float32Array([1, 0, 0, 0]));
      repo.store('evt-2', 'ws-1', new Float32Array([0, 1, 0, 0]));

      expect(repo.count()).toBe(2);
    });
  });
});
