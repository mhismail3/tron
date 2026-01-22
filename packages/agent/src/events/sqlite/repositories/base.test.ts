/**
 * @fileoverview Tests for Base Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../../../src/events/sqlite/database.js';
import { BaseRepository, idUtils, rowUtils } from '../../../../src/events/sqlite/repositories/base.js';

// Concrete implementation for testing
class TestRepository extends BaseRepository {
  createTestTable(): void {
    this.exec('CREATE TABLE test (id TEXT PRIMARY KEY, name TEXT, active INTEGER)');
  }

  insert(id: string, name: string, active: boolean): void {
    this.run('INSERT INTO test (id, name, active) VALUES (?, ?, ?)', id, name, active ? 1 : 0);
  }

  findById(id: string): { id: string; name: string; active: number } | undefined {
    return this.get('SELECT * FROM test WHERE id = ?', id);
  }

  findAll(): Array<{ id: string; name: string; active: number }> {
    return this.all('SELECT * FROM test');
  }

  findByIds(ids: string[]): Array<{ id: string; name: string; active: number }> {
    const placeholders = this.inPlaceholders(ids);
    return this.all(`SELECT * FROM test WHERE id IN (${placeholders})`, ...ids);
  }

  generateTestId(): string {
    return this.generateId('test');
  }

  getCurrentTimestamp(): string {
    return this.now();
  }

  runInTransaction<T>(fn: () => T): T {
    return this.transaction(fn);
  }

  async runInAsyncTransaction<T>(fn: () => Promise<T>): Promise<T> {
    return this.transactionAsync(fn);
  }
}

describe('BaseRepository', () => {
  let connection: DatabaseConnection;
  let repo: TestRepository;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    connection.open();
    repo = new TestRepository(connection);
    repo.createTestTable();
  });

  afterEach(() => {
    connection.close();
  });

  describe('CRUD operations', () => {
    it('should insert and find by id', () => {
      repo.insert('id1', 'Test Item', true);

      const result = repo.findById('id1');
      expect(result).toBeDefined();
      expect(result?.id).toBe('id1');
      expect(result?.name).toBe('Test Item');
      expect(result?.active).toBe(1);
    });

    it('should return undefined for non-existent id', () => {
      const result = repo.findById('nonexistent');
      expect(result).toBeUndefined();
    });

    it('should find all records', () => {
      repo.insert('id1', 'Item 1', true);
      repo.insert('id2', 'Item 2', false);
      repo.insert('id3', 'Item 3', true);

      const results = repo.findAll();
      expect(results).toHaveLength(3);
    });

    it('should find by multiple ids', () => {
      repo.insert('id1', 'Item 1', true);
      repo.insert('id2', 'Item 2', false);
      repo.insert('id3', 'Item 3', true);

      const results = repo.findByIds(['id1', 'id3']);
      expect(results).toHaveLength(2);
      expect(results.map(r => r.id).sort()).toEqual(['id1', 'id3']);
    });

    it('should handle empty ids array', () => {
      repo.insert('id1', 'Item 1', true);

      const results = repo.findByIds([]);
      expect(results).toHaveLength(0);
    });
  });

  describe('generateId', () => {
    it('should generate ID with prefix', () => {
      const id = repo.generateTestId();
      expect(id).toMatch(/^test_[a-f0-9]{12}$/);
    });

    it('should generate unique IDs', () => {
      const ids = new Set<string>();
      for (let i = 0; i < 100; i++) {
        ids.add(repo.generateTestId());
      }
      expect(ids.size).toBe(100);
    });
  });

  describe('now', () => {
    it('should return ISO timestamp', () => {
      const timestamp = repo.getCurrentTimestamp();
      expect(() => new Date(timestamp)).not.toThrow();
      expect(new Date(timestamp).toISOString()).toBe(timestamp);
    });
  });

  describe('transaction', () => {
    it('should execute function within transaction', () => {
      const result = repo.runInTransaction(() => {
        repo.insert('id1', 'Item 1', true);
        repo.insert('id2', 'Item 2', false);
        return repo.findAll().length;
      });

      expect(result).toBe(2);
    });
  });

  describe('transactionAsync', () => {
    it('should execute async function within transaction', async () => {
      const result = await repo.runInAsyncTransaction(async () => {
        repo.insert('id1', 'Item 1', true);
        await Promise.resolve();
        repo.insert('id2', 'Item 2', false);
        return repo.findAll().length;
      });

      expect(result).toBe(2);
    });
  });
});

describe('idUtils', () => {
  describe('generate', () => {
    it('should generate ID with prefix and default length', () => {
      const id = idUtils.generate('foo');
      expect(id).toMatch(/^foo_[a-f0-9]{12}$/);
    });

    it('should generate ID with custom length', () => {
      const id = idUtils.generate('bar', 8);
      expect(id).toMatch(/^bar_[a-f0-9]{8}$/);
    });
  });

  describe('domain-specific generators', () => {
    it('should generate workspace ID', () => {
      const id = idUtils.workspace();
      expect(id).toMatch(/^ws_[a-f0-9]{12}$/);
    });

    it('should generate session ID', () => {
      const id = idUtils.session();
      expect(id).toMatch(/^sess_[a-f0-9]{12}$/);
    });

    it('should generate event ID', () => {
      const id = idUtils.event();
      expect(id).toMatch(/^evt_[a-f0-9]{12}$/);
    });

    it('should generate branch ID', () => {
      const id = idUtils.branch();
      expect(id).toMatch(/^br_[a-f0-9]{12}$/);
    });

    it('should generate blob ID', () => {
      const id = idUtils.blob();
      expect(id).toMatch(/^blob_[a-f0-9]{12}$/);
    });
  });
});

describe('rowUtils', () => {
  describe('parseJson', () => {
    it('should parse valid JSON', () => {
      const result = rowUtils.parseJson('["a","b","c"]', []);
      expect(result).toEqual(['a', 'b', 'c']);
    });

    it('should return fallback for null', () => {
      const result = rowUtils.parseJson(null, []);
      expect(result).toEqual([]);
    });

    it('should return fallback for invalid JSON', () => {
      const result = rowUtils.parseJson('not json', { default: true });
      expect(result).toEqual({ default: true });
    });

    it('should handle complex objects', () => {
      const data = { name: 'test', items: [1, 2, 3], nested: { a: 1 } };
      const result = rowUtils.parseJson(JSON.stringify(data), {});
      expect(result).toEqual(data);
    });
  });

  describe('toBoolean', () => {
    it('should convert 1 to true', () => {
      expect(rowUtils.toBoolean(1)).toBe(true);
    });

    it('should convert 0 to false', () => {
      expect(rowUtils.toBoolean(0)).toBe(false);
    });

    it('should convert null to false', () => {
      expect(rowUtils.toBoolean(null)).toBe(false);
    });

    it('should convert other numbers to false', () => {
      expect(rowUtils.toBoolean(2)).toBe(false);
      expect(rowUtils.toBoolean(-1)).toBe(false);
    });
  });

  describe('fromBoolean', () => {
    it('should convert true to 1', () => {
      expect(rowUtils.fromBoolean(true)).toBe(1);
    });

    it('should convert false to 0', () => {
      expect(rowUtils.fromBoolean(false)).toBe(0);
    });
  });
});
