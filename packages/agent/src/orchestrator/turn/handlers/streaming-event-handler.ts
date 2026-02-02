/**
 * @fileoverview Streaming Event Handler
 *
 * Handles real-time streaming events:
 * - message_update: Text streaming deltas
 * - toolcall_delta: Tool argument streaming
 * - thinking_start/delta/end: Extended thinking lifecycle
 *
 * These events are ephemeral - they're emitted in real-time for UI streaming
 * but not persisted individually. Content is accumulated and persisted
 * as part of message.assistant events at turn end.
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import { createLogger } from '../../../logging/index.js';
import type { TronEvent } from '../../../types/index.js';
import type { EventContext } from '../event-context.js';
import type { UIRenderHandler } from '../../ui-render-handler.js';

const logger = createLogger('streaming-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for StreamingEventHandler.
 *
 * Note: No longer needs getActiveSession, appendEventLinearized, or emit
 * since EventContext provides all of these.
 */
export interface StreamingEventHandlerDeps {
  /** UI render handler for tool call delta processing */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// StreamingEventHandler
// =============================================================================

/**
 * Handles real-time streaming events for UI updates.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in events
 * - Consistent timestamp across related events
 * - Access to active session for state updates
 */
export class StreamingEventHandler {
  constructor(private deps: StreamingEventHandlerDeps) {}

  /**
   * Handle message_update event.
   * Accumulates text deltas for persistence and emits for real-time streaming.
   */
  handleMessageUpdate(ctx: EventContext, event: TronEvent): void {
    const msgEvent = event as { content?: string };

    // STREAMING ONLY - NOT PERSISTED TO EVENT STORE
    // Text deltas are accumulated in TurnContentTracker for:
    // 1. Real-time WebSocket emission (agent.text_delta below)
    // 2. Client catch-up when resuming into running session
    // 3. Building consolidated message.assistant at turn_end (which IS persisted)
    //
    // Individual deltas are ephemeral by design - high frequency, low reconstruction value.
    // The source of truth is the message.assistant event created at turn_end.
    if (ctx.active && typeof msgEvent.content === 'string') {
      ctx.active.sessionContext!.addTextDelta(msgEvent.content);
    }

    ctx.emit('agent.text_delta', { delta: msgEvent.content });
  }

  /**
   * Handle toolcall_delta event.
   * Streams tool call arguments for progressive UI rendering (e.g., RenderAppUI).
   */
  handleToolCallDelta(ctx: EventContext, event: TronEvent): void {
    const delta = event as {
      toolCallId: string;
      toolName?: string;
      argumentsDelta: string;
    };

    // Delegate to UIRenderHandler which handles RenderAppUI-specific processing
    this.deps.uiRenderHandler.handleToolCallDelta(
      ctx.sessionId,
      delta.toolCallId,
      delta.toolName,
      delta.argumentsDelta,
      ctx.timestamp,
      ctx.runId
    );
  }

  /**
   * Handle thinking_start event.
   * Emits WebSocket event for real-time UI streaming.
   */
  handleThinkingStart(ctx: EventContext): void {
    logger.debug('Received thinking_start', { sessionId: ctx.sessionId, runId: ctx.runId });
    ctx.emit('agent.thinking_start');
  }

  /**
   * Handle thinking_delta event.
   * Accumulates thinking content for persistence and emits for real-time streaming.
   */
  handleThinkingDelta(ctx: EventContext, event: TronEvent): void {
    const delta = event as { delta: string };

    // Accumulate thinking content in TurnContentTracker for persistence
    // This ensures thinking is included in the message.assistant event at turn end
    if (ctx.active) {
      ctx.active.sessionContext!.addThinkingDelta(delta.delta);
    }

    // Emit WebSocket event for real-time UI streaming
    // Thinking deltas are NOT persisted individually (like text deltas)
    // They're accumulated and persisted as part of message.assistant at turn end
    ctx.emit('agent.thinking_delta', { delta: delta.delta });
  }

  /**
   * Handle thinking_end event.
   * Stores signature for API compliance and emits completion event.
   */
  handleThinkingEnd(ctx: EventContext, event: TronEvent): void {
    const thinkingEnd = event as { thinking: string; signature?: string };

    logger.debug('Received thinking_end', {
      sessionId: ctx.sessionId,
      runId: ctx.runId,
      thinkingLength: thinkingEnd.thinking.length,
      hasSignature: !!thinkingEnd.signature,
    });

    // Store the signature in TurnContentTracker for persistence
    // IMPORTANT: API requires signature when sending thinking blocks back
    if (ctx.active && thinkingEnd.signature) {
      ctx.active.sessionContext!.setThinkingSignature(thinkingEnd.signature);
    }

    ctx.emit('agent.thinking_end', {
      thinking: thinkingEnd.thinking,
      signature: thinkingEnd.signature,
    });
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a StreamingEventHandler instance.
 */
export function createStreamingEventHandler(
  deps: StreamingEventHandlerDeps
): StreamingEventHandler {
  return new StreamingEventHandler(deps);
}
