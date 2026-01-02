/**
 * @fileoverview Memory module exports
 *
 * Simplified memory system with ledger, handoff, and memory store support.
 */

export * from './types.js';
export {
  LedgerManager,
  createLedgerManager,
  type Ledger,
  type Decision,
  type LedgerManagerConfig,
} from './ledger-manager.js';
export {
  HandoffManager,
  createHandoffManager,
  type Handoff,
  type CodeChange,
  type HandoffSearchResult,
  type HandoffManagerConfig,
} from './handoff-manager.js';
export {
  SQLiteMemoryStore,
  createMemoryStore,
  type MemoryEntry,
  type AddEntryOptions,
  type SearchOptions,
  type SearchResult,
  type MemoryStoreConfig,
} from './memory-store.js';
