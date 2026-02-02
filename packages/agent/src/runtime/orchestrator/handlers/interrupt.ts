/**
 * @fileoverview InterruptHandler - Interrupted Session Content Persistence
 *
 * Handles persisting content when an agent run is interrupted.
 * Builds the event sequence needed to preserve partial work.
 *
 * ## Event Sequence
 *
 * When interrupted, we persist:
 * 1. `message.assistant` - Partial response with interrupted flag
 * 2. `message.user` - Tool results (if any completed)
 * 3. `notification.interrupted` - Interrupt marker for reconstruction
 *
 * ## Usage
 *
 * ```typescript
 * const handler = createInterruptHandler();
 *
 * // Build events from interrupted context
 * const events = handler.buildInterruptEvents({
 *   sessionId: 'session_1',
 *   turn: 1,
 *   model: 'claude-sonnet-4-20250514',
 *   assistantContent: interruptedContent.assistantContent,
 *   toolResultContent: interruptedContent.toolResultContent,
 *   tokenUsage: runResult.totalTokenUsage,
 * });
 *
 * // Persist events via EventPersister
 * for (const event of events) {
 *   await persister.appendAsync(event.type, event.payload);
 * }
 * ```
 */
import { createLogger } from '@infrastructure/logging/index.js';
import type { EventType } from '@infrastructure/events/types.js';

const logger = createLogger('interrupt-handler');

// =============================================================================
// Types
// =============================================================================

/** Token usage information */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}

/** Content block types for assistant message */
export interface TextContentBlock {
  type: 'text';
  text: string;
}

export interface ToolUseContentBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input: Record<string, unknown>;
  _meta?: {
    status?: string;
    interrupted?: boolean;
    durationMs?: number;
  };
}

export type AssistantContentBlock = TextContentBlock | ToolUseContentBlock;

/** Tool result content block */
export interface ToolResultContentBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
  is_error: boolean;
  _meta?: {
    interrupted?: boolean;
    durationMs?: number;
    toolName?: string;
  };
}

/** Context for building interrupt events */
export interface InterruptContext {
  sessionId: string;
  turn: number;
  model: string;
  assistantContent: AssistantContentBlock[];
  toolResultContent: ToolResultContentBlock[];
  tokenUsage?: TokenUsage;
}

/** Event to be persisted */
export interface EventToAppend {
  type: EventType;
  payload: Record<string, unknown>;
}

/** Result from handling interrupt */
export interface InterruptResult {
  events: EventToAppend[];
  hadContent: boolean;
}

// =============================================================================
// InterruptHandler Class
// =============================================================================

/**
 * Handles building events for interrupted sessions.
 *
 * This handler doesn't persist directly - it builds the event sequence
 * that should be persisted by the caller using EventPersister.
 */
export class InterruptHandler {
  // ===========================================================================
  // Main API
  // ===========================================================================

  /**
   * Build the event sequence for an interrupted session.
   *
   * Returns an array of events that should be persisted in order.
   * The caller is responsible for persisting these events.
   *
   * @param context - The interrupt context with content to persist
   * @returns Array of events to append
   */
  buildInterruptEvents(context: InterruptContext): EventToAppend[] {
    const events: EventToAppend[] = [];
    const turn = Math.max(1, context.turn); // Ensure minimum turn of 1

    // 1. Build assistant message event (if content exists)
    if (context.assistantContent.length > 0) {
      events.push({
        type: 'message.assistant' as EventType,
        payload: {
          content: context.assistantContent,
          tokenUsage: context.tokenUsage,
          turn,
          model: context.model,
          stopReason: 'interrupted',
          interrupted: true,
        },
      });

      logger.debug('Built assistant message event', {
        sessionId: context.sessionId,
        contentBlocks: context.assistantContent.length,
      });
    }

    // 2. Build tool results message event (if results exist)
    if (context.toolResultContent.length > 0) {
      events.push({
        type: 'message.user' as EventType,
        payload: {
          content: context.toolResultContent,
        },
      });

      logger.debug('Built tool results event', {
        sessionId: context.sessionId,
        resultCount: context.toolResultContent.length,
      });
    }

    // 3. Always add notification.interrupted event
    events.push({
      type: 'notification.interrupted' as EventType,
      payload: {
        timestamp: new Date().toISOString(),
        turn,
      },
    });

    logger.debug('Built interrupt events', {
      sessionId: context.sessionId,
      eventCount: events.length,
      hadAssistantContent: context.assistantContent.length > 0,
      hadToolResults: context.toolResultContent.length > 0,
    });

    return events;
  }

  /**
   * Check if there's any content to persist.
   */
  hasContent(context: InterruptContext): boolean {
    return (
      context.assistantContent.length > 0 ||
      context.toolResultContent.length > 0
    );
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an InterruptHandler instance.
 */
export function createInterruptHandler(): InterruptHandler {
  return new InterruptHandler();
}
