/**
 * @fileoverview Compaction Event Handler
 *
 * Handles context compaction events:
 * - compaction_complete: Context window compaction finished
 *
 * Broadcasts compaction status to clients and persists boundary events
 * for session resume support.
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import { createLogger } from '../../../logging/index.js';
import type { TronEvent } from '../../../types/index.js';
import type { EventType } from '../../../events/index.js';
import type { EventContext } from '../event-context.js';

const logger = createLogger('compaction-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for CompactionEventHandler.
 *
 * Note: No longer needs getActiveSession, appendEventLinearized, or emit
 * since EventContext provides all of these.
 */
export interface CompactionEventHandlerDeps {
  // No dependencies needed - EventContext provides everything
}

// =============================================================================
// CompactionEventHandler
// =============================================================================

/**
 * Handles context compaction events.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in events
 * - Consistent timestamp across related events
 * - Simplified emit/persist API
 */
export class CompactionEventHandler {
  constructor(_deps: CompactionEventHandlerDeps) {
    // No deps needed - EventContext provides everything
  }

  /**
   * Handle compaction_complete event.
   * Broadcasts to clients and persists boundary event for session resume.
   */
  handleCompactionComplete(ctx: EventContext, event: TronEvent): void {
    const compactionEvent = event as {
      tokensBefore?: number;
      tokensAfter?: number;
      compressionRatio?: number;
      reason?: string;
      success?: boolean;
      summary?: string;
    };

    const reason = compactionEvent.reason || 'auto';

    // Broadcast streaming event for live clients
    ctx.emit('agent.compaction', {
      tokensBefore: compactionEvent.tokensBefore,
      tokensAfter: compactionEvent.tokensAfter,
      compressionRatio: compactionEvent.compressionRatio,
      reason,
      summary: compactionEvent.summary,
    });

    // Persist compact.boundary event so it shows up on session resume
    // Only persist successful compactions
    if (compactionEvent.success !== false) {
      ctx.persist('compact.boundary' as EventType, {
        originalTokens: compactionEvent.tokensBefore,
        compactedTokens: compactionEvent.tokensAfter,
        compressionRatio: compactionEvent.compressionRatio,
        reason,
        summary: compactionEvent.summary,
      });

      logger.debug('Persisted compact.boundary event', {
        sessionId: ctx.sessionId,
        tokensBefore: compactionEvent.tokensBefore,
        tokensAfter: compactionEvent.tokensAfter,
        reason,
      });
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a CompactionEventHandler instance.
 */
export function createCompactionEventHandler(
  deps: CompactionEventHandlerDeps
): CompactionEventHandler {
  return new CompactionEventHandler(deps);
}
