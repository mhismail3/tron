/**
 * @fileoverview Tests for Memory Adapter
 *
 * The memory adapter is deprecated and returns empty results.
 * These tests verify the deprecated behavior is maintained.
 */

import { describe, it, expect } from 'vitest';
import { createMemoryAdapter } from '../memory.adapter.js';

describe('MemoryAdapter (deprecated)', () => {
  describe('searchEntries', () => {
    it('should return empty results', async () => {
      const adapter = createMemoryAdapter();
      const result = await adapter.searchEntries({
        searchText: 'test query',
        limit: 10,
      });

      expect(result).toEqual({
        entries: [],
        totalCount: 0,
      });
    });

    it('should ignore all parameters and return empty', async () => {
      const adapter = createMemoryAdapter();
      const result = await adapter.searchEntries({
        searchText: 'anything',
        source: 'project',
        limit: 100,
        type: 'pattern',
      });

      expect(result.entries).toHaveLength(0);
      expect(result.totalCount).toBe(0);
    });
  });

  describe('addEntry', () => {
    it('should return empty id (no-op)', async () => {
      const adapter = createMemoryAdapter();
      const result = await adapter.addEntry({
        content: 'Some content',
        type: 'lesson',
      });

      expect(result).toEqual({ id: '' });
    });
  });

  describe('listHandoffs', () => {
    it('should return empty array', async () => {
      const adapter = createMemoryAdapter();
      const result = await adapter.listHandoffs('/some/directory', 10);

      expect(result).toEqual([]);
    });

    it('should return empty array with no arguments', async () => {
      const adapter = createMemoryAdapter();
      const result = await adapter.listHandoffs();

      expect(result).toEqual([]);
    });
  });
});
