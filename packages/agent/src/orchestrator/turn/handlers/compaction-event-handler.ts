/**
 * @fileoverview Compaction Event Handler
 *
 * Handles context compaction events:
 * - compaction_complete: Context window compaction finished
 *
 * Broadcasts compaction status to clients and persists boundary events
 * for session resume support.
 *
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import { createLogger } from '../../../logging/index.js';
import type { TronEvent } from '../../../types/events.js';
import type { SessionId, EventType } from '../../../events/index.js';

const logger = createLogger('compaction-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for CompactionEventHandler
 */
export interface CompactionEventHandlerDeps {
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// CompactionEventHandler
// =============================================================================

/**
 * Handles context compaction events.
 */
export class CompactionEventHandler {
  constructor(private deps: CompactionEventHandlerDeps) {}

  /**
   * Handle compaction_complete event.
   * Broadcasts to clients and persists boundary event for session resume.
   */
  handleCompactionComplete(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
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
    this.deps.emit('agent_event', {
      type: 'agent.compaction',
      sessionId,
      timestamp,
      data: {
        tokensBefore: compactionEvent.tokensBefore,
        tokensAfter: compactionEvent.tokensAfter,
        compressionRatio: compactionEvent.compressionRatio,
        reason,
        summary: compactionEvent.summary,
      },
    });

    // Persist compact.boundary event so it shows up on session resume
    // Only persist successful compactions
    if (compactionEvent.success !== false) {
      this.deps.appendEventLinearized(sessionId, 'compact.boundary' as EventType, {
        originalTokens: compactionEvent.tokensBefore,
        compactedTokens: compactionEvent.tokensAfter,
        compressionRatio: compactionEvent.compressionRatio,
        reason,
        summary: compactionEvent.summary,
      });

      logger.debug('Persisted compact.boundary event', {
        sessionId,
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
