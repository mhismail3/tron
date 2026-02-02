/**
 * @fileoverview Memory domain - Memory and message operations
 *
 * Handles memory search, entries, and handoffs.
 */

// Re-export handler factory
export { createMemoryHandlers } from '@interface/rpc/handlers/memory.handler.js';

// Re-export types
export type {
  MemorySearchParams,
  RpcMemorySearchResult,
  MemorySearchResultRpc,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
} from '@interface/rpc/types/memory.js';
