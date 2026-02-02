/**
 * @fileoverview Memory domain - Memory and message operations
 *
 * Handles memory search, entries, and handoffs.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleMemorySearch,
  handleMemoryAddEntry,
  handleMemoryGetHandoffs,
  createMemoryHandlers,
} from '../../../../rpc/handlers/memory.handler.js';

// Re-export types
export type {
  MemorySearchParams,
  RpcMemorySearchResult,
  MemorySearchResultRpc,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
} from '../../../../rpc/types/memory.js';
