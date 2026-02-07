/**
 * @fileoverview Memory Module
 *
 * Three-pillar memory system:
 * 1. Raw session history (existing event store)
 * 2. Automatic ledger entries (LedgerWriter + Haiku subagent)
 * 3. Smart compaction (CompactionTrigger + MemoryManager)
 */

export { LedgerWriter, createLedgerWriter } from './ledger-writer.js';
export type { LedgerWriterDeps, LedgerWriteOpts, LedgerWriteResult } from './ledger-writer.js';

export { CompactionTrigger, createCompactionTrigger } from './compaction-trigger.js';
export type { CompactionTriggerInput, CompactionTriggerResult, CompactionTriggerConfig } from './compaction-trigger.js';

export { MemoryManager, createMemoryManager } from './memory-manager.js';
export type { MemoryManagerDeps, CycleInfo } from './memory-manager.js';
