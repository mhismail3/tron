/**
 * @fileoverview Subagent Forwarder
 *
 * Forwards streaming events from subagent sessions to their parent sessions.
 * This enables real-time updates in the iOS detail sheet for nested agents.
 *
 * Forwarded events:
 * - message_update → text_delta
 * - tool_execution_start → tool_start
 * - tool_execution_end → tool_end
 * - turn_start/turn_end
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import type { TronEvent } from '../../../types/index.js';
import type { SessionId } from '../../../events/index.js';
import type { EventContext } from '../event-context.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for SubagentForwarder.
 *
 * Note: No longer needs emit since EventContext provides this.
 */
export interface SubagentForwarderDeps {
  // No dependencies needed - EventContext provides everything
}

// =============================================================================
// SubagentForwarder
// =============================================================================

/**
 * Forwards streaming events from subagent sessions to parent sessions.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in events
 * - Consistent timestamp across related events
 * - Simplified emit API
 */
export class SubagentForwarder {
  /** Event types that should be forwarded to parent sessions */
  private static readonly FORWARDABLE_TYPES = [
    'message_update',       // Text deltas
    'tool_execution_start', // Tool start
    'tool_execution_end',   // Tool end
    'turn_start',           // Turn lifecycle
    'turn_end',
  ];

  constructor(_deps: SubagentForwarderDeps) {
    // No deps needed - EventContext provides everything
  }

  /**
   * Forward an event from a subagent to its parent session.
   * Maps event types to iOS-friendly format for detail sheet display.
   *
   * @param ctx - EventContext scoped to the parent session
   * @param subagentSessionId - Session ID of the subagent
   * @param event - Event from the subagent
   */
  forwardToParent(
    ctx: EventContext,
    subagentSessionId: SessionId,
    event: TronEvent
  ): void {
    if (!SubagentForwarder.FORWARDABLE_TYPES.includes(event.type)) {
      return;
    }

    const mapped = this.mapEvent(event, subagentSessionId, ctx.timestamp);
    if (!mapped) {
      return;
    }

    const { eventType, eventData, statusUpdate } = mapped;

    // Emit status update if needed (for turn_start)
    if (statusUpdate) {
      ctx.emit('agent.subagent_status', statusUpdate);
    }

    // Emit the forwarded event to parent session
    ctx.emit('agent.subagent_event', {
      subagentSessionId,
      event: {
        type: eventType,
        data: eventData,
        timestamp: ctx.timestamp,
      },
    });
  }

  /**
   * Map event to iOS-friendly format.
   */
  private mapEvent(
    event: TronEvent,
    subagentSessionId: SessionId,
    _timestamp: string
  ): { eventType: string; eventData: unknown; statusUpdate?: Record<string, unknown> } | null {
    switch (event.type) {
      case 'message_update': {
        const msgEvent = event as { content?: string };
        return {
          eventType: 'text_delta',
          eventData: { delta: msgEvent.content },
        };
      }

      case 'tool_execution_start': {
        const toolEvent = event as {
          toolCallId: string;
          toolName: string;
          arguments?: unknown;
        };
        return {
          eventType: 'tool_start',
          eventData: {
            toolCallId: toolEvent.toolCallId,
            toolName: toolEvent.toolName,
            arguments: toolEvent.arguments,
          },
        };
      }

      case 'tool_execution_end': {
        const toolEvent = event as {
          toolCallId: string;
          toolName: string;
          result: unknown;
          isError?: boolean;
          duration?: number;
        };
        return {
          eventType: 'tool_end',
          eventData: {
            toolCallId: toolEvent.toolCallId,
            toolName: toolEvent.toolName,
            success: !toolEvent.isError,
            result:
              typeof toolEvent.result === 'string'
                ? toolEvent.result
                : JSON.stringify(toolEvent.result),
            duration: toolEvent.duration,
          },
        };
      }

      case 'turn_start': {
        const turnEvent = event as { turn?: number };
        return {
          eventType: 'turn_start',
          eventData: { turn: turnEvent.turn },
          statusUpdate: {
            subagentSessionId,
            status: 'running',
            currentTurn: turnEvent.turn ?? 1,
          },
        };
      }

      case 'turn_end': {
        const turnEvent = event as { turn?: number };
        return {
          eventType: 'turn_end',
          eventData: { turn: turnEvent.turn },
        };
      }

      default:
        return null;
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a SubagentForwarder instance.
 */
export function createSubagentForwarder(
  deps: SubagentForwarderDeps
): SubagentForwarder {
  return new SubagentForwarder(deps);
}
