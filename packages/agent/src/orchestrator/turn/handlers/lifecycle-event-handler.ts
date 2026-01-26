/**
 * @fileoverview Lifecycle Event Handler
 *
 * Handles agent lifecycle events:
 * - agent_start: Agent run begins
 * - agent_end: Agent run completes
 * - agent_interrupted: Agent was interrupted
 * - api_retry: Provider retry events
 *
 * These events manage session state transitions and error handling.
 *
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import type { TronEvent } from '../../../types/events.js';
import type { SessionId, EventType } from '../../../events/index.js';
import type { ActiveSession } from '../../types.js';
import type { UIRenderHandler } from '../../ui-render-handler.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for LifecycleEventHandler
 */
export interface LifecycleEventHandlerDeps {
  /** Default provider for error events */
  defaultProvider: string;
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
  /** UI render handler for cleanup on agent_end */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// LifecycleEventHandler
// =============================================================================

/**
 * Handles agent lifecycle events.
 */
export class LifecycleEventHandler {
  constructor(private deps: LifecycleEventHandlerDeps) {}

  /**
   * Handle agent_start event.
   * Clears accumulation for fresh tracking and emits turn_start signal.
   */
  handleAgentStart(
    sessionId: SessionId,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Clear accumulation at the start of a new agent run
    // This ensures fresh tracking for the new runAgent call
    if (active) {
      active.sessionContext!.onAgentStart();
    }

    this.deps.emit('agent_event', {
      type: 'agent.turn_start',
      sessionId,
      timestamp,
      data: {},
    });
  }

  /**
   * Handle agent_end event.
   * Clears accumulation and cleans up UI render state.
   */
  handleAgentEnd(active: ActiveSession | undefined): void {
    // Clear accumulation when agent run completes
    // Content is now persisted in EventStore, no need for catch-up tracking
    if (active) {
      active.sessionContext!.onAgentEnd();
    }

    // Clean up any orphaned UI render tracking state
    this.deps.uiRenderHandler.cleanup();

    // NOTE: agent.complete is now emitted in runAgent() AFTER all events are persisted
    // This ensures linearized events (message.assistant, tool.call, tool.result)
    // are in the database before iOS syncs on receiving agent.complete
  }

  /**
   * Handle agent_interrupted event.
   * Emits completion event with interrupted status.
   */
  handleAgentInterrupted(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const interruptedEvent = event as { partialContent?: unknown };

    this.deps.emit('agent_event', {
      type: 'agent.complete',
      sessionId,
      timestamp,
      data: {
        success: false,
        interrupted: true,
        partialContent: interruptedEvent.partialContent,
      },
    });
  }

  /**
   * Handle api_retry event.
   * Persists provider error event for retryable errors.
   */
  handleApiRetry(sessionId: SessionId, event: TronEvent): void {
    const retryEvent = event as {
      errorMessage?: string;
      errorCategory?: string;
      delayMs?: number;
    };

    this.deps.appendEventLinearized(sessionId, 'error.provider' as EventType, {
      provider: this.deps.defaultProvider,
      error: retryEvent.errorMessage,
      code: retryEvent.errorCategory,
      retryable: true,
      retryAfter: retryEvent.delayMs,
    });
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a LifecycleEventHandler instance.
 */
export function createLifecycleEventHandler(
  deps: LifecycleEventHandlerDeps
): LifecycleEventHandler {
  return new LifecycleEventHandler(deps);
}
