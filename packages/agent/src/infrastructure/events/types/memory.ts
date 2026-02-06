/**
 * @fileoverview Memory Events
 *
 * Events for the memory ledger system. Ledger entries are structured
 * summaries of response cycles, written by a background Haiku subagent.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Memory Ledger Payload
// =============================================================================

export interface MemoryLedgerPayload {
  /** Event range this entry covers */
  eventRange: { firstEventId: string; lastEventId: string };
  /** Turn range this entry covers */
  turnRange: { firstTurn: number; lastTurn: number };
  /** Short title for the entry */
  title: string;
  /** Classification of the work done */
  entryType: 'feature' | 'bugfix' | 'refactor' | 'docs' | 'config' | 'research' | 'conversation';
  /** Current status */
  status: 'completed' | 'partial' | 'in_progress';
  /** Tags for categorization */
  tags: string[];
  /** Original user request summary */
  input: string;
  /** Actions taken */
  actions: string[];
  /** Files touched */
  files: Array<{ path: string; op: 'C' | 'M' | 'D'; why: string }>;
  /** Key decisions and rationale */
  decisions: Array<{ choice: string; reason: string }>;
  /** Patterns and lessons for future reference */
  lessons: string[];
  /** Key reasoning insights from thinking blocks */
  thinkingInsights: string[];
  /** Token cost of the cycle */
  tokenCost: { input: number; output: number };
  /** Model used */
  model: string;
  /** Working directory at time of entry */
  workingDirectory: string;
}

// =============================================================================
// Memory Events
// =============================================================================

export interface MemoryLedgerEvent extends BaseEvent {
  type: 'memory.ledger';
  payload: MemoryLedgerPayload;
}
