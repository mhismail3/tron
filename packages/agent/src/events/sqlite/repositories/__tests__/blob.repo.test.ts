/**
 * @fileoverview Tests for Blob Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { BlobRepository } from '../../repositories/blob.repo.js';

describe('BlobRepository', () => {
  let connection: DatabaseConnection;
  let repo: BlobRepository;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new BlobRepository(connection);
  });

  afterEach(() => {
    connection.close();
  });

  describe('store', () => {
    it('should store string content as blob', () => {
      const id = repo.store('Hello, World!');

      expect(id).toMatch(/^blob_[a-f0-9]+$/);

      const content = repo.getContent(id);
      expect(content).toBe('Hello, World!');
    });

    it('should store buffer content as blob', () => {
      const buffer = Buffer.from('Binary data', 'utf-8');
      const id = repo.store(buffer);

      const content = repo.getContent(id);
      expect(content).toBe('Binary data');
    });

    it('should use custom mime type', () => {
      const id = repo.store('{"key": "value"}', 'application/json');

      const blob = repo.getById(id);
      expect(blob?.mime_type).toBe('application/json');
    });

    it('should deduplicate by hash', () => {
      const content = 'Duplicate content';

      const id1 = repo.store(content);
      const id2 = repo.store(content);

      // Should return same ID
      expect(id1).toBe(id2);

      // Should have incremented ref count
      expect(repo.getRefCount(id1)).toBe(2);
    });

    it('should create different blobs for different content', () => {
      const id1 = repo.store('Content A');
      const id2 = repo.store('Content B');

      expect(id1).not.toBe(id2);
    });
  });

  describe('getContent', () => {
    it('should return null for non-existent blob', () => {
      const content = repo.getContent('blob_nonexistent');
      expect(content).toBeNull();
    });

    it('should return blob content', () => {
      const id = repo.store('Test content');
      const content = repo.getContent(id);
      expect(content).toBe('Test content');
    });
  });

  describe('getById', () => {
    it('should return null for non-existent blob', () => {
      const blob = repo.getById('blob_nonexistent');
      expect(blob).toBeNull();
    });

    it('should return full blob record', () => {
      const id = repo.store('Test content', 'text/plain');

      const blob = repo.getById(id);
      expect(blob).toBeDefined();
      expect(blob?.id).toBe(id);
      expect(blob?.mime_type).toBe('text/plain');
      expect(blob?.size_original).toBe(Buffer.from('Test content').length);
      expect(blob?.ref_count).toBe(1);
    });
  });

  describe('getByHash', () => {
    it('should return null for non-existent hash', () => {
      const blob = repo.getByHash('0'.repeat(64));
      expect(blob).toBeNull();
    });

    it('should return blob by hash', () => {
      const content = 'Find by hash';
      const id = repo.store(content);

      const blob = repo.getById(id);
      const foundBlob = repo.getByHash(blob!.hash);

      expect(foundBlob).toBeDefined();
      expect(foundBlob?.id).toBe(id);
    });
  });

  describe('getRefCount', () => {
    it('should return 0 for non-existent blob', () => {
      const count = repo.getRefCount('blob_nonexistent');
      expect(count).toBe(0);
    });

    it('should return reference count', () => {
      const id = repo.store('Content');
      expect(repo.getRefCount(id)).toBe(1);

      // Store same content again
      repo.store('Content');
      expect(repo.getRefCount(id)).toBe(2);
    });
  });

  describe('incrementRefCount', () => {
    it('should increment reference count', () => {
      const id = repo.store('Content');
      expect(repo.getRefCount(id)).toBe(1);

      repo.incrementRefCount(id);
      expect(repo.getRefCount(id)).toBe(2);

      repo.incrementRefCount(id);
      expect(repo.getRefCount(id)).toBe(3);
    });
  });

  describe('decrementRefCount', () => {
    it('should decrement reference count', () => {
      const id = repo.store('Content');
      repo.incrementRefCount(id);
      expect(repo.getRefCount(id)).toBe(2);

      const newCount = repo.decrementRefCount(id);
      expect(newCount).toBe(1);
    });

    it('should not go below zero', () => {
      const id = repo.store('Content');
      expect(repo.getRefCount(id)).toBe(1);

      repo.decrementRefCount(id);
      expect(repo.getRefCount(id)).toBe(0);

      // Try to decrement again
      repo.decrementRefCount(id);
      expect(repo.getRefCount(id)).toBe(0);
    });
  });

  describe('deleteUnreferenced', () => {
    it('should delete blobs with zero references', () => {
      const id1 = repo.store('Content 1');
      const id2 = repo.store('Content 2');

      // Decrement ref count to 0 for first blob
      repo.decrementRefCount(id1);

      const deleted = repo.deleteUnreferenced();
      expect(deleted).toBe(1);

      expect(repo.getById(id1)).toBeNull();
      expect(repo.getById(id2)).toBeDefined();
    });

    it('should return 0 when no unreferenced blobs', () => {
      repo.store('Content 1');
      repo.store('Content 2');

      const deleted = repo.deleteUnreferenced();
      expect(deleted).toBe(0);
    });
  });

  describe('count', () => {
    it('should return 0 for empty table', () => {
      expect(repo.count()).toBe(0);
    });

    it('should return number of blobs', () => {
      repo.store('Content 1');
      repo.store('Content 2');
      repo.store('Content 3');

      expect(repo.count()).toBe(3);
    });

    it('should not count duplicates', () => {
      repo.store('Same content');
      repo.store('Same content');
      repo.store('Same content');

      expect(repo.count()).toBe(1);
    });
  });

  describe('getTotalSize', () => {
    it('should return zeros for empty table', () => {
      const size = repo.getTotalSize();
      expect(size.original).toBe(0);
      expect(size.compressed).toBe(0);
    });

    it('should return total size of all blobs', () => {
      repo.store('Short');
      repo.store('A bit longer content');

      const size = repo.getTotalSize();
      expect(size.original).toBe(
        Buffer.from('Short').length + Buffer.from('A bit longer content').length
      );
    });
  });
});
