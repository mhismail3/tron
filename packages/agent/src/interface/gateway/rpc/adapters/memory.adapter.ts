/**
 * @fileoverview Memory Adapter (Deprecated)
 *
 * @deprecated Memory operations have been moved to event store search.
 * These methods are kept for backward compatibility but return empty results.
 * Use `eventStore.searchContent()` instead.
 */

import type { MemoryStoreAdapter } from '../types.js';

/**
 * Creates a deprecated MemoryStore adapter that returns empty results
 *
 * @deprecated Use eventStore.searchContent() instead
 */
export function createMemoryAdapter(): MemoryStoreAdapter {
  return {
    /**
     * @deprecated Use eventStore.searchContent() instead
     */
    async searchEntries(_params) {
      return { entries: [], totalCount: 0 };
    },

    /**
     * @deprecated No longer supported
     */
    async addEntry(_params) {
      return { id: '' };
    },

    /**
     * @deprecated Use eventStore.getEventHistory() instead
     */
    async listHandoffs(_workingDirectory, _limit) {
      return [];
    },
  };
}
