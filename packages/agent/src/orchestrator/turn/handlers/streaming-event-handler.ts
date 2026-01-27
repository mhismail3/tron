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
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import { createLogger } from '../../../logging/index.js';
import type { TronEvent } from '../../../types/index.js';
import type { SessionId } from '../../../events/index.js';
import type { ActiveSession } from '../../types.js';
import type { UIRenderHandler } from '../../ui-render-handler.js';

const logger = createLogger('streaming-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for StreamingEventHandler
 */
export interface StreamingEventHandlerDeps {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
  /** UI render handler for tool call delta processing */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// StreamingEventHandler
// =============================================================================

/**
 * Handles real-time streaming events for UI updates.
 */
export class StreamingEventHandler {
  constructor(private deps: StreamingEventHandlerDeps) {}

  /**
   * Handle message_update event.
   * Accumulates text deltas for persistence and emits for real-time streaming.
   */
  handleMessageUpdate(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    const msgEvent = event as { content?: string };

    // STREAMING ONLY - NOT PERSISTED TO EVENT STORE
    // Text deltas are accumulated in TurnContentTracker for:
    // 1. Real-time WebSocket emission (agent.text_delta below)
    // 2. Client catch-up when resuming into running session
    // 3. Building consolidated message.assistant at turn_end (which IS persisted)
    //
    // Individual deltas are ephemeral by design - high frequency, low reconstruction value.
    // The source of truth is the message.assistant event created at turn_end.
    if (active && typeof msgEvent.content === 'string') {
      active.sessionContext!.addTextDelta(msgEvent.content);
    }

    this.deps.emit('agent_event', {
      type: 'agent.text_delta',
      sessionId,
      timestamp,
      data: { delta: msgEvent.content },
    });
  }

  /**
   * Handle toolcall_delta event.
   * Streams tool call arguments for progressive UI rendering (e.g., RenderAppUI).
   */
  handleToolCallDelta(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const delta = event as {
      toolCallId: string;
      toolName?: string;
      argumentsDelta: string;
    };

    // Delegate to UIRenderHandler which handles RenderAppUI-specific processing
    this.deps.uiRenderHandler.handleToolCallDelta(
      sessionId,
      delta.toolCallId,
      delta.toolName,
      delta.argumentsDelta,
      timestamp
    );
  }

  /**
   * Handle thinking_start event.
   * Emits WebSocket event for real-time UI streaming.
   */
  handleThinkingStart(sessionId: SessionId, timestamp: string): void {
    logger.debug('Received thinking_start', { sessionId });

    this.deps.emit('agent_event', {
      type: 'agent.thinking_start',
      sessionId,
      timestamp,
    });
  }

  /**
   * Handle thinking_delta event.
   * Accumulates thinking content for persistence and emits for real-time streaming.
   */
  handleThinkingDelta(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    const delta = event as { delta: string };

    // Accumulate thinking content in TurnContentTracker for persistence
    // This ensures thinking is included in the message.assistant event at turn end
    if (active) {
      active.sessionContext!.addThinkingDelta(delta.delta);
    }

    // Emit WebSocket event for real-time UI streaming
    // Thinking deltas are NOT persisted individually (like text deltas)
    // They're accumulated and persisted as part of message.assistant at turn end
    this.deps.emit('agent_event', {
      type: 'agent.thinking_delta',
      sessionId,
      timestamp,
      data: { delta: delta.delta },
    });
  }

  /**
   * Handle thinking_end event.
   * Stores signature for API compliance and emits completion event.
   */
  handleThinkingEnd(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const thinkingEnd = event as { thinking: string; signature?: string };

    logger.debug('Received thinking_end', {
      sessionId,
      thinkingLength: thinkingEnd.thinking.length,
      hasSignature: !!thinkingEnd.signature,
    });

    // Store the signature in TurnContentTracker for persistence
    // IMPORTANT: API requires signature when sending thinking blocks back
    const active = this.deps.getActiveSession(sessionId);
    if (active && thinkingEnd.signature) {
      active.sessionContext!.setThinkingSignature(thinkingEnd.signature);
    }

    this.deps.emit('agent_event', {
      type: 'agent.thinking_end',
      sessionId,
      timestamp,
      data: { thinking: thinkingEnd.thinking, signature: thinkingEnd.signature },
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
