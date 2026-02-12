/**
 * @fileoverview Turn Event Handler
 *
 * Handles turn lifecycle events:
 * - turn_start: Beginning of a turn
 * - turn_end: End of a turn with message creation and token tracking
 * - response_complete: LLM streaming finished (before tools)
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { calculateCost } from '@infrastructure/usage/index.js';
import type { TronEvent } from '@core/types/index.js';
import type { EventType } from '@infrastructure/events/index.js';
import { normalizeContentBlocks } from '@core/utils/index.js';
import type { EventContext } from '../event-context.js';
import type { TokenRecord } from '@infrastructure/tokens/index.js';

const logger = createLogger('turn-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for TurnEventHandler.
 *
 * Note: No longer needs getActiveSession, appendEventLinearized, or emit
 * since EventContext provides all of these.
 */
export interface TurnEventHandlerDeps {
  // No dependencies needed - EventContext provides everything
}

// =============================================================================
// TurnEventHandler
// =============================================================================

/**
 * Handles turn lifecycle events.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in events
 * - Consistent timestamp across related events
 * - Access to active session for state updates
 * - Simplified emit/persist API
 */
export class TurnEventHandler {
  constructor(_deps: TurnEventHandlerDeps) {
    // No deps needed - EventContext provides everything
  }

  /**
   * Handle turn_start event.
   * Updates turn tracking and emits WebSocket event.
   */
  handleTurnStart(ctx: EventContext, event: TronEvent): void {
    const turnStartEvent = event as { turn?: number };

    // Update current turn for tool event tracking
    if (ctx.active && turnStartEvent.turn !== undefined) {
      ctx.active.sessionContext!.startTurn(turnStartEvent.turn);
    }

    ctx.emit('agent.turn_start', { turn: turnStartEvent.turn });

    // Store turn start event (linearized to prevent spurious branches)
    ctx.persist('stream.turn_start' as EventType, { turn: turnStartEvent.turn });
  }

  /**
   * Handle turn_end event.
   * Creates message.assistant event, calculates cost, and persists stream.turn_end.
   */
  handleTurnEnd(ctx: EventContext, event: TronEvent): void {
    const turnEndEvent = event as {
      turn?: number;
      duration?: number;
      cost?: number;
      tokenUsage?: {
        inputTokens: number;
        outputTokens: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
      };
    };

    // Track turnResult for tokenRecord access
    let turnResult: { turn: number; content: unknown[]; tokenRecord?: TokenRecord } | undefined;

    // CREATE MESSAGE.ASSISTANT FOR THIS TURN - BUT ONLY IF NOT ALREADY FLUSHED
    // Linear event ordering means content with tool_use is flushed at first tool_execution_start.
    // Only create message.assistant here if:
    // 1. No pre-tool content was flushed (no tools in this turn), OR
    // 2. This is a simple text-only response (no tools)
    if (ctx.active) {
      // Check if pre-tool content was already flushed (tools were called this turn)
      const wasPreToolFlushed = ctx.active.sessionContext!.hasPreToolContentFlushed();

      // Use SessionContext for turn end
      // Token usage was already set via setResponseTokenUsage when response_complete fired
      // This returns built content blocks, clears per-turn tracking, and includes tokenRecord
      const turnStartTime = ctx.active.sessionContext!.getTurnStartTime();
      turnResult = ctx.active.sessionContext!.endTurn();

      // Sync API token count to ContextManager for consistent RPC responses
      // This ensures context sheet and progress bar show the same value
      const tokenRecord = turnResult?.tokenRecord;
      if (tokenRecord?.computed.contextWindowTokens !== undefined) {
        ctx.active.agent.getContextManager().setApiContextTokens(
          tokenRecord.computed.contextWindowTokens
        );
      }

      // Only create message.assistant if we didn't already flush content for tools
      // If wasPreToolFlushed is true, the content was already emitted at tool_execution_start
      if (!wasPreToolFlushed && turnResult.content.length > 0) {
        this.createMessageAssistantEvent(ctx, turnResult, turnStartTime, turnEndEvent.duration);
      } else if (wasPreToolFlushed) {
        logger.debug('Skipped message.assistant at turn_end (content already flushed for tools)', {
          sessionId: ctx.sessionId,
          turn: turnResult.turn,
        });
      }
    }

    // Calculate cost if not provided by agent (or is 0) but tokenUsage is available
    const turnCost = this.calculateTurnCost(turnEndEvent, ctx.active);

    ctx.emit('agent.turn_end', {
      turn: turnEndEvent.turn,
      duration: turnEndEvent.duration,
      tokenUsage: turnEndEvent.tokenUsage,
      tokenRecord: turnResult?.tokenRecord,
      cost: turnCost,
    });

    // Store turn end event with token record and cost (linearized)
    this.persistStreamTurnEnd(ctx, turnEndEvent, turnResult, turnCost);
  }

  /**
   * Handle response_complete event.
   * Fires when LLM streaming finishes, BEFORE tools execute.
   * Captures token usage early so message.assistant events always include it.
   */
  handleResponseComplete(ctx: EventContext, event: TronEvent): void {
    if (!ctx.active?.sessionContext) {
      return;
    }

    const responseEvent = event as {
      turn: number;
      tokenUsage?: {
        inputTokens: number;
        outputTokens: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
        cacheCreation5mTokens?: number;
        cacheCreation1hTokens?: number;
      };
    };

    // Set token usage immediately - this creates a TokenRecord
    // before any tool execution starts
    if (responseEvent.tokenUsage) {
      ctx.active.sessionContext.setResponseTokenUsage(responseEvent.tokenUsage, ctx.sessionId);

      const tokenRecord = ctx.active.sessionContext.getLastTokenRecord();

      logger.info('[TOKEN-FLOW] 2. handleResponseComplete - setResponseTokenUsage called', {
        sessionId: ctx.sessionId,
        turn: responseEvent.turn,
        source: tokenRecord
          ? {
              rawInputTokens: tokenRecord.source.rawInputTokens,
              rawOutputTokens: tokenRecord.source.rawOutputTokens,
              rawCacheReadTokens: tokenRecord.source.rawCacheReadTokens,
              rawCacheCreationTokens: tokenRecord.source.rawCacheCreationTokens,
              rawCacheCreation5mTokens: tokenRecord.source.rawCacheCreation5mTokens,
              rawCacheCreation1hTokens: tokenRecord.source.rawCacheCreation1hTokens,
            }
          : 'NOT_COMPUTED',
        computed: tokenRecord
          ? {
              newInputTokens: tokenRecord.computed.newInputTokens,
              contextWindowTokens: tokenRecord.computed.contextWindowTokens,
              calculationMethod: tokenRecord.computed.calculationMethod,
            }
          : 'NOT_COMPUTED',
      });
    } else {
      logger.warn('[TOKEN-FLOW] 2. handleResponseComplete - NO tokenUsage in event', {
        sessionId: ctx.sessionId,
        turn: responseEvent.turn,
      });
    }
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Create and persist message.assistant event for a turn without tools.
   */
  private createMessageAssistantEvent(
    ctx: EventContext,
    turnResult: { turn: number; content: unknown[]; tokenRecord?: TokenRecord; tokenUsage?: unknown },
    turnStartTime: number | undefined,
    eventDuration: number | undefined
  ): void {
    const turnLatency = turnStartTime
      ? Date.now() - turnStartTime
      : eventDuration ?? 0;

    // Detect if content has thinking blocks
    const hasThinking = turnResult.content.some(
      (b) => (b as Record<string, unknown>).type === 'thinking'
    );

    // Normalize content blocks
    const normalizedContent = normalizeContentBlocks(turnResult.content);

    if (normalizedContent.length === 0) {
      return;
    }

    ctx.persist(
      'message.assistant' as EventType,
      {
        content: normalizedContent,
        tokenUsage: turnResult.tokenUsage,
        tokenRecord: turnResult.tokenRecord,
        turn: turnResult.turn,
        model: ctx.active!.model,
        stopReason: 'end_turn',
        latency: turnLatency,
        hasThinking,
      }
    );

    const tokenRecord = turnResult.tokenRecord;

    logger.info('[TOKEN-FLOW] 3b. Turn-end message.assistant created (no tools case)', {
      sessionId: ctx.sessionId,
      turn: turnResult.turn,
      contentBlocks: normalizedContent.length,
      tokenRecord: tokenRecord
        ? {
            source: {
              rawInputTokens: tokenRecord.source.rawInputTokens,
              rawOutputTokens: tokenRecord.source.rawOutputTokens,
              rawCacheReadTokens: tokenRecord.source.rawCacheReadTokens,
            },
            computed: {
              newInputTokens: tokenRecord.computed.newInputTokens,
              contextWindowTokens: tokenRecord.computed.contextWindowTokens,
            },
          }
        : 'MISSING',
      latency: turnLatency,
    });
  }

  /**
   * Calculate turn cost from token usage.
   */
  private calculateTurnCost(
    turnEndEvent: {
      cost?: number;
      tokenUsage?: {
        inputTokens: number;
        outputTokens: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
        cacheCreation5mTokens?: number;
        cacheCreation1hTokens?: number;
      };
    },
    active: EventContext['active']
  ): number | undefined {
    let turnCost = turnEndEvent.cost;

    if (turnEndEvent.tokenUsage && active) {
      const costResult = calculateCost(active.model, {
        inputTokens: turnEndEvent.tokenUsage.inputTokens,
        outputTokens: turnEndEvent.tokenUsage.outputTokens,
        cacheReadTokens: turnEndEvent.tokenUsage.cacheReadTokens,
        cacheCreationTokens: turnEndEvent.tokenUsage.cacheCreationTokens,
        cacheCreation5mTokens: turnEndEvent.tokenUsage.cacheCreation5mTokens,
        cacheCreation1hTokens: turnEndEvent.tokenUsage.cacheCreation1hTokens,
      });
      // Use calculated cost if agent didn't provide one or provided 0
      if (turnCost === undefined || turnCost === 0) {
        turnCost = costResult.total;
      }
    }

    return turnCost;
  }

  /**
   * Persist stream.turn_end event with token record and cost data.
   */
  private persistStreamTurnEnd(
    ctx: EventContext,
    turnEndEvent: { turn?: number; tokenUsage?: { inputTokens: number; outputTokens: number; cacheReadTokens?: number } },
    turnResult: { tokenRecord?: TokenRecord } | undefined,
    turnCost: number | undefined
  ): void {
    const tokenRecord = turnResult?.tokenRecord;

    logger.info('[TOKEN-FLOW] 4. stream.turn_end persisted', {
      sessionId: ctx.sessionId,
      turn: turnEndEvent.turn,
      tokenRecord: tokenRecord
        ? {
            source: {
              rawInputTokens: tokenRecord.source.rawInputTokens,
              rawOutputTokens: tokenRecord.source.rawOutputTokens,
              rawCacheReadTokens: tokenRecord.source.rawCacheReadTokens,
              rawCacheCreationTokens: tokenRecord.source.rawCacheCreationTokens,
              rawCacheCreation5m: tokenRecord.source.rawCacheCreation5mTokens,
              rawCacheCreation1h: tokenRecord.source.rawCacheCreation1hTokens,
            },
            computed: {
              newInputTokens: tokenRecord.computed.newInputTokens,
              contextWindowTokens: tokenRecord.computed.contextWindowTokens,
            },
          }
        : 'MISSING',
      cost: turnCost,
    });

    ctx.persist('stream.turn_end' as EventType, {
      turn: turnEndEvent.turn,
      tokenUsage: turnEndEvent.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
      tokenRecord: turnResult?.tokenRecord,
      cost: turnCost,
    });
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a TurnEventHandler instance.
 */
export function createTurnEventHandler(deps: TurnEventHandlerDeps): TurnEventHandler {
  return new TurnEventHandler(deps);
}
