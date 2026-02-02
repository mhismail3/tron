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
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import type { TronEvent } from '../../../types/index.js';
import type { EventType } from '../../../events/index.js';
import type { EventContext } from '../event-context.js';
import type { UIRenderHandler } from '../../ui-render-handler.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for LifecycleEventHandler.
 *
 * Note: No longer needs getActiveSession, appendEventLinearized, or emit
 * since EventContext provides all of these.
 */
export interface LifecycleEventHandlerDeps {
  /** Default provider for error events */
  defaultProvider: string;
  /** UI render handler for cleanup on agent_end */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// LifecycleEventHandler
// =============================================================================

/**
 * Handles agent lifecycle events.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in events
 * - Consistent timestamp across related events
 * - Access to active session for state updates
 * - Simplified emit/persist API
 */
export class LifecycleEventHandler {
  constructor(private deps: LifecycleEventHandlerDeps) {}

  /**
   * Handle agent_start event.
   * Clears accumulation for fresh tracking and emits turn_start signal.
   */
  handleAgentStart(ctx: EventContext): void {
    // Clear accumulation at the start of a new agent run
    // This ensures fresh tracking for the new runAgent call
    if (ctx.active) {
      ctx.active.sessionContext!.onAgentStart();
    }

    ctx.emit('agent.turn_start', {});
  }

  /**
   * Handle agent_end event.
   * Clears accumulation and cleans up UI render state.
   */
  handleAgentEnd(ctx: EventContext): void {
    // Clear accumulation when agent run completes
    // Content is now persisted in EventStore, no need for catch-up tracking
    if (ctx.active) {
      ctx.active.sessionContext!.onAgentEnd();
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
  handleAgentInterrupted(ctx: EventContext, event: TronEvent): void {
    const interruptedEvent = event as { partialContent?: unknown };

    ctx.emit('agent.complete', {
      success: false,
      interrupted: true,
      partialContent: interruptedEvent.partialContent,
    });
  }

  /**
   * Handle api_retry event.
   * Persists provider error event for retryable errors.
   */
  handleApiRetry(ctx: EventContext, event: TronEvent): void {
    const retryEvent = event as {
      errorMessage?: string;
      errorCategory?: string;
      delayMs?: number;
    };

    ctx.persist('error.provider' as EventType, {
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
