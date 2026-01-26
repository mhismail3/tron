/**
 * @fileoverview ContextClearHandler - Context Clear Event Building
 *
 * Builds events for context clearing operations.
 * Context clearing removes all messages without preserving a summary.
 *
 * ## Usage
 *
 * ```typescript
 * const handler = createContextClearHandler();
 *
 * // After clearing context on ContextManager
 * const event = handler.buildClearEvent({
 *   sessionId: 'session_1',
 *   tokensBefore: 100000,
 *   tokensAfter: 5000,
 *   reason: 'manual',
 * });
 *
 * // Persist event via EventPersister
 * await persister.appendAsync(event.type, event.payload);
 * ```
 */
import { createLogger } from '../../logging/index.js';
import type { EventType } from '../../events/types.js';

const logger = createLogger('context-clear-handler');

// =============================================================================
// Types
// =============================================================================

/** Reason for clearing context */
export type ClearReason = 'manual' | 'automatic';

/** Context for building clear event */
export interface ContextClearContext {
  sessionId: string;
  tokensBefore: number;
  tokensAfter: number;
  reason: ClearReason;
}

/** Event to be persisted */
export interface EventToAppend {
  type: EventType;
  payload: Record<string, unknown>;
}

// =============================================================================
// ContextClearHandler Class
// =============================================================================

/**
 * Handles building events for context clear operations.
 *
 * This handler doesn't execute clearing or persist directly - it builds
 * the event that should be persisted by the caller.
 */
export class ContextClearHandler {
  // ===========================================================================
  // Main API
  // ===========================================================================

  /**
   * Build the event for a context clear operation.
   *
   * @param context - The clear context with token stats
   * @returns Event to append
   */
  buildClearEvent(context: ContextClearContext): EventToAppend {
    const event: EventToAppend = {
      type: 'context.cleared' as EventType,
      payload: {
        tokensBefore: context.tokensBefore,
        tokensAfter: context.tokensAfter,
        reason: context.reason,
      },
    };

    logger.debug('Built context clear event', {
      sessionId: context.sessionId,
      tokensBefore: context.tokensBefore,
      tokensAfter: context.tokensAfter,
      tokensFreed: context.tokensBefore - context.tokensAfter,
      reason: context.reason,
    });

    return event;
  }

  /**
   * Calculate tokens freed by the clear operation.
   */
  calculateTokensFreed(context: ContextClearContext): number {
    return context.tokensBefore - context.tokensAfter;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a ContextClearHandler instance.
 */
export function createContextClearHandler(): ContextClearHandler {
  return new ContextClearHandler();
}
