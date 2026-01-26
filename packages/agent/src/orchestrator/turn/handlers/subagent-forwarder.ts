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
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import type { TronEvent } from '../../../types/events.js';
import type { SessionId } from '../../../events/index.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for SubagentForwarder
 */
export interface SubagentForwarderDeps {
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// SubagentForwarder
// =============================================================================

/**
 * Forwards streaming events from subagent sessions to parent sessions.
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

  constructor(private deps: SubagentForwarderDeps) {}

  /**
   * Forward an event from a subagent to its parent session.
   * Maps event types to iOS-friendly format for detail sheet display.
   */
  forwardToParent(
    subagentSessionId: SessionId,
    parentSessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    if (!SubagentForwarder.FORWARDABLE_TYPES.includes(event.type)) {
      return;
    }

    const mapped = this.mapEvent(event, subagentSessionId, parentSessionId, timestamp);
    if (!mapped) {
      return;
    }

    const { eventType, eventData, statusUpdate } = mapped;

    // Emit status update if needed (for turn_start)
    if (statusUpdate) {
      this.deps.emit('agent_event', statusUpdate);
    }

    // Emit the forwarded event to parent session
    this.deps.emit('agent_event', {
      type: 'agent.subagent_event',
      sessionId: parentSessionId,
      timestamp,
      data: {
        subagentSessionId,
        event: {
          type: eventType,
          data: eventData,
          timestamp,
        },
      },
    });
  }

  /**
   * Map event to iOS-friendly format.
   */
  private mapEvent(
    event: TronEvent,
    subagentSessionId: SessionId,
    parentSessionId: SessionId,
    timestamp: string
  ): { eventType: string; eventData: unknown; statusUpdate?: unknown } | null {
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
            type: 'agent.subagent_status',
            sessionId: parentSessionId,
            timestamp,
            data: {
              subagentSessionId,
              status: 'running',
              currentTurn: turnEvent.turn ?? 1,
            },
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
