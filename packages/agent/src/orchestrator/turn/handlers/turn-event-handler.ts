/**
 * @fileoverview Turn Event Handler
 *
 * Handles turn lifecycle events:
 * - turn_start: Beginning of a turn
 * - turn_end: End of a turn with message creation and token tracking
 * - response_complete: LLM streaming finished (before tools)
 *
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import { createLogger } from '../../../logging/index.js';
import { calculateCost } from '../../../usage/index.js';
import type { TronEvent } from '../../../types/events.js';
import type { SessionId, EventType, TronSessionEvent } from '../../../events/index.js';
import { normalizeContentBlocks } from '../../../utils/content-normalizer.js';
import type { ActiveSession } from '../../types.js';
import type { NormalizedTokenUsage } from '../turn-content-tracker.js';

const logger = createLogger('turn-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for TurnEventHandler
 */
export interface TurnEventHandlerDeps {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// TurnEventHandler
// =============================================================================

/**
 * Handles turn lifecycle events.
 */
export class TurnEventHandler {
  constructor(private deps: TurnEventHandlerDeps) {}

  /**
   * Handle turn_start event.
   * Updates turn tracking and emits WebSocket event.
   */
  handleTurnStart(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const active = this.deps.getActiveSession(sessionId);
    const turnStartEvent = event as { turn?: number };

    // Update current turn for tool event tracking
    if (active && turnStartEvent.turn !== undefined) {
      active.sessionContext!.startTurn(turnStartEvent.turn);
    }

    this.deps.emit('agent_event', {
      type: 'agent.turn_start',
      sessionId,
      timestamp,
      data: { turn: turnStartEvent.turn },
    });

    // Store turn start event (linearized to prevent spurious branches)
    this.deps.appendEventLinearized(
      sessionId,
      'stream.turn_start' as EventType,
      { turn: turnStartEvent.turn }
    );
  }

  /**
   * Handle turn_end event.
   * Creates message.assistant event, calculates cost, and persists stream.turn_end.
   */
  handleTurnEnd(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const active = this.deps.getActiveSession(sessionId);
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

    // Track turnResult for normalizedUsage access
    let turnResult: { turn: number; content: unknown[]; normalizedUsage?: unknown } | undefined;

    // CREATE MESSAGE.ASSISTANT FOR THIS TURN - BUT ONLY IF NOT ALREADY FLUSHED
    // Linear event ordering means content with tool_use is flushed at first tool_execution_start.
    // Only create message.assistant here if:
    // 1. No pre-tool content was flushed (no tools in this turn), OR
    // 2. This is a simple text-only response (no tools)
    if (active) {
      // Check if pre-tool content was already flushed (tools were called this turn)
      const wasPreToolFlushed = active.sessionContext!.hasPreToolContentFlushed();

      // Use SessionContext for turn end
      // Token usage was already set via setResponseTokenUsage when response_complete fired
      // This returns built content blocks, clears per-turn tracking, and includes normalizedUsage
      const turnStartTime = active.sessionContext!.getTurnStartTime();
      turnResult = active.sessionContext!.endTurn();

      // Sync API token count to ContextManager for consistent RPC responses
      // This ensures context sheet and progress bar show the same value
      const normalizedUsage = turnResult?.normalizedUsage as NormalizedTokenUsage | undefined;
      if (normalizedUsage?.contextWindowTokens !== undefined) {
        active.agent.getContextManager().setApiContextTokens(
          normalizedUsage.contextWindowTokens
        );
      }

      // Only create message.assistant if we didn't already flush content for tools
      // If wasPreToolFlushed is true, the content was already emitted at tool_execution_start
      if (!wasPreToolFlushed && turnResult.content.length > 0) {
        this.createMessageAssistantEvent(
          sessionId,
          active,
          turnResult,
          turnStartTime,
          turnEndEvent.duration
        );
      } else if (wasPreToolFlushed) {
        logger.debug('Skipped message.assistant at turn_end (content already flushed for tools)', {
          sessionId,
          turn: turnResult.turn,
        });
      }
    }

    // Calculate cost if not provided by agent (or is 0) but tokenUsage is available
    const turnCost = this.calculateTurnCost(turnEndEvent, active);

    this.deps.emit('agent_event', {
      type: 'agent.turn_end',
      sessionId,
      timestamp,
      data: {
        turn: turnEndEvent.turn,
        duration: turnEndEvent.duration,
        tokenUsage: turnEndEvent.tokenUsage,
        normalizedUsage: turnResult?.normalizedUsage,
        cost: turnCost,
      },
    });

    // Store turn end event with token usage, normalized usage, and cost (linearized)
    this.persistStreamTurnEnd(sessionId, turnEndEvent, turnResult, turnCost);
  }

  /**
   * Handle response_complete event.
   * Fires when LLM streaming finishes, BEFORE tools execute.
   * Captures token usage early so message.assistant events always include it.
   */
  handleResponseComplete(
    sessionId: SessionId,
    event: TronEvent
  ): void {
    const active = this.deps.getActiveSession(sessionId);
    if (!active?.sessionContext) {
      return;
    }

    const responseEvent = event as {
      turn: number;
      tokenUsage?: {
        inputTokens: number;
        outputTokens: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
      };
    };

    // Set token usage immediately - this computes normalizedUsage
    // before any tool execution starts
    if (responseEvent.tokenUsage) {
      active.sessionContext.setResponseTokenUsage(responseEvent.tokenUsage);

      const normalizedUsage = active.sessionContext.getLastNormalizedUsage();

      logger.info('[TOKEN-FLOW] 2. handleResponseComplete - setResponseTokenUsage called', {
        sessionId,
        turn: responseEvent.turn,
        rawTokenUsage: {
          inputTokens: responseEvent.tokenUsage.inputTokens,
          outputTokens: responseEvent.tokenUsage.outputTokens,
          cacheRead: responseEvent.tokenUsage.cacheReadTokens ?? 0,
          cacheCreation: responseEvent.tokenUsage.cacheCreationTokens ?? 0,
        },
        normalizedUsage: normalizedUsage
          ? {
              newInputTokens: normalizedUsage.newInputTokens,
              contextWindowTokens: normalizedUsage.contextWindowTokens,
              outputTokens: normalizedUsage.outputTokens,
            }
          : 'NOT_COMPUTED',
      });
    } else {
      logger.warn('[TOKEN-FLOW] 2. handleResponseComplete - NO tokenUsage in event', {
        sessionId,
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
    sessionId: SessionId,
    active: ActiveSession,
    turnResult: { turn: number; content: unknown[]; normalizedUsage?: unknown; tokenUsage?: unknown },
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

    this.deps.appendEventLinearized(
      sessionId,
      'message.assistant' as EventType,
      {
        content: normalizedContent,
        tokenUsage: turnResult.tokenUsage,
        normalizedUsage: turnResult.normalizedUsage,
        turn: turnResult.turn,
        model: active.model,
        stopReason: 'end_turn',
        latency: turnLatency,
        hasThinking,
      },
      (evt) => {
        // Track eventId for context manager message via SessionContext
        const currentActive = this.deps.getActiveSession(sessionId);
        if (currentActive?.sessionContext) {
          currentActive.sessionContext.addMessageEventId(evt.id);
        }
      }
    );

    const tokenUsageForLog = turnResult.tokenUsage as { inputTokens: number; outputTokens: number; cacheReadTokens?: number } | undefined;
    const normalizedForLog = turnResult.normalizedUsage as NormalizedTokenUsage | undefined;

    logger.info('[TOKEN-FLOW] 3b. Turn-end message.assistant created (no tools case)', {
      sessionId,
      turn: turnResult.turn,
      contentBlocks: normalizedContent.length,
      tokenUsage: tokenUsageForLog
        ? {
            inputTokens: tokenUsageForLog.inputTokens,
            outputTokens: tokenUsageForLog.outputTokens,
            cacheRead: tokenUsageForLog.cacheReadTokens ?? 0,
          }
        : 'MISSING',
      normalizedUsage: normalizedForLog
        ? {
            newInputTokens: normalizedForLog.newInputTokens,
            contextWindowTokens: normalizedForLog.contextWindowTokens,
            outputTokens: normalizedForLog.outputTokens,
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
      };
    },
    active: ActiveSession | undefined
  ): number | undefined {
    let turnCost = turnEndEvent.cost;

    if (turnEndEvent.tokenUsage && active) {
      const costResult = calculateCost(active.model, {
        inputTokens: turnEndEvent.tokenUsage.inputTokens,
        outputTokens: turnEndEvent.tokenUsage.outputTokens,
        cacheReadTokens: turnEndEvent.tokenUsage.cacheReadTokens,
        cacheCreationTokens: turnEndEvent.tokenUsage.cacheCreationTokens,
      });
      // Use calculated cost if agent didn't provide one or provided 0
      if (turnCost === undefined || turnCost === 0) {
        turnCost = costResult.total;
      }
    }

    return turnCost;
  }

  /**
   * Persist stream.turn_end event with token and cost data.
   */
  private persistStreamTurnEnd(
    sessionId: SessionId,
    turnEndEvent: { turn?: number; tokenUsage?: { inputTokens: number; outputTokens: number; cacheReadTokens?: number } },
    turnResult: { normalizedUsage?: unknown } | undefined,
    turnCost: number | undefined
  ): void {
    const normalizedUsage = turnResult?.normalizedUsage as NormalizedTokenUsage | undefined;

    logger.info('[TOKEN-FLOW] 4. stream.turn_end persisted', {
      sessionId,
      turn: turnEndEvent.turn,
      tokenUsage: turnEndEvent.tokenUsage
        ? {
            inputTokens: turnEndEvent.tokenUsage.inputTokens,
            outputTokens: turnEndEvent.tokenUsage.outputTokens,
            cacheRead: turnEndEvent.tokenUsage.cacheReadTokens ?? 0,
          }
        : 'MISSING',
      normalizedUsage: normalizedUsage
        ? {
            newInputTokens: normalizedUsage.newInputTokens,
            contextWindowTokens: normalizedUsage.contextWindowTokens,
            outputTokens: normalizedUsage.outputTokens,
          }
        : 'MISSING',
      cost: turnCost,
    });

    this.deps.appendEventLinearized(
      sessionId,
      'stream.turn_end' as EventType,
      {
        turn: turnEndEvent.turn,
        tokenUsage: turnEndEvent.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
        normalizedUsage: turnResult?.normalizedUsage,
        cost: turnCost,
      }
    );
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
