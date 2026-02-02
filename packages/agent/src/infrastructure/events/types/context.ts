/**
 * @fileoverview Context Events
 *
 * Events for context clearing operations.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Context Clearing Events
// =============================================================================

/**
 * Context cleared event - marks where context was cleared
 * Unlike compaction, no summary is preserved - all messages before this point are discarded
 */
export interface ContextClearedEvent extends BaseEvent {
  type: 'context.cleared';
  payload: {
    /** Token count before clearing */
    tokensBefore: number;
    /** Token count after clearing (system prompt + tools only) */
    tokensAfter: number;
    /** Reason for clearing */
    reason: 'manual';
  };
}
