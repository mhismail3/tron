/**
 * @fileoverview CompactionHandler - Compaction Event Building
 *
 * Builds events for context compaction operations.
 * Compaction reduces context size by summarizing older messages.
 *
 * ## Event Sequence
 *
 * When compaction occurs, we persist:
 * 1. `compact.boundary` - Marks the compaction point with token stats
 * 2. `compact.summary` - Contains the summary text
 *
 * ## Usage
 *
 * ```typescript
 * const handler = createCompactionHandler();
 *
 * // After executing compaction on ContextManager
 * const events = handler.buildCompactionEvents({
 *   sessionId: 'session_1',
 *   tokensBefore: 150000,
 *   tokensAfter: 30000,
 *   compressionRatio: 0.8,
 *   summary: result.summary,
 *   keyDecisions: result.extractedData?.keyDecisions,
 *   filesModified: result.extractedData?.filesModified,
 * });
 *
 * // Persist events via EventPersister
 * await persister.appendMultiple(events);
 * ```
 */
import { createLogger } from '@infrastructure/logging/index.js';
import type { EventType } from '@infrastructure/events/types.js';

const logger = createLogger('compaction-handler');

// =============================================================================
// Types
// =============================================================================

/** Context for building compaction events */
export interface CompactionContext {
  sessionId: string;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  summary: string;
  keyDecisions?: string[];
  filesModified?: string[];
}

/** Event to be persisted */
export interface EventToAppend {
  type: EventType;
  payload: Record<string, unknown>;
}

// =============================================================================
// CompactionHandler Class
// =============================================================================

/**
 * Handles building events for compaction operations.
 *
 * This handler doesn't execute compaction or persist directly - it builds
 * the event sequence that should be persisted by the caller.
 */
export class CompactionHandler {
  // ===========================================================================
  // Main API
  // ===========================================================================

  /**
   * Build the event sequence for a compaction operation.
   *
   * Returns an array of events that should be persisted in order:
   * 1. compact.boundary - Token stats
   * 2. compact.summary - Summary text
   *
   * @param context - The compaction context with stats and summary
   * @returns Array of events to append
   */
  buildCompactionEvents(context: CompactionContext): EventToAppend[] {
    const events: EventToAppend[] = [];

    // 1. Build boundary event with token stats
    events.push({
      type: 'compact.boundary' as EventType,
      payload: {
        originalTokens: context.tokensBefore,
        compactedTokens: context.tokensAfter,
        compressionRatio: context.compressionRatio,
      },
    });

    // 2. Build summary event
    const summaryPayload: Record<string, unknown> = {
      summary: context.summary,
    };

    // Only include optional fields if they have values
    if (context.keyDecisions !== undefined) {
      summaryPayload.keyDecisions = context.keyDecisions;
    }
    if (context.filesModified !== undefined) {
      summaryPayload.filesModified = context.filesModified;
    }

    events.push({
      type: 'compact.summary' as EventType,
      payload: summaryPayload,
    });

    logger.debug('Built compaction events', {
      sessionId: context.sessionId,
      tokensBefore: context.tokensBefore,
      tokensAfter: context.tokensAfter,
      compressionRatio: context.compressionRatio,
    });

    return events;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a CompactionHandler instance.
 */
export function createCompactionHandler(): CompactionHandler {
  return new CompactionHandler();
}
