/**
 * @fileoverview Hook Event Handler - Persists Hook Lifecycle Events
 *
 * Handles hook_triggered and hook_completed events from the agent,
 * persisting them to the event store for linearized audit logging.
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 */

import type { HookType, HookAction } from '@capabilities/extensions/hooks/types.js';
import type { EventContext } from '../event-context.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('hook-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for HookEventHandler.
 *
 * Note: No longer needs getActiveSession, appendEventLinearized, or emit
 * since EventContext provides all of these.
 */
export interface HookEventHandlerDeps {
  // No dependencies needed - EventContext provides everything
}

/**
 * Internal event type for hook triggered - emitted by agent
 */
export interface InternalHookTriggeredEvent {
  type: 'hook_triggered';
  sessionId: string;
  timestamp: string;
  hookNames: string[];
  hookEvent: HookType;
  toolName?: string;
  toolCallId?: string;
}

/**
 * Internal event type for hook completed - emitted by agent
 */
export interface InternalHookCompletedEvent {
  type: 'hook_completed';
  sessionId: string;
  timestamp: string;
  hookNames: string[];
  hookEvent: HookType;
  result: HookAction;
  duration?: number;
  reason?: string;
  toolName?: string;
  toolCallId?: string;
}

// =============================================================================
// HookEventHandler Class
// =============================================================================

/**
 * Handles hook lifecycle events, persisting them to the event store.
 * Follows fail-open pattern - errors are logged but don't stop execution.
 *
 * Uses EventContext for:
 * - Automatic runId inclusion in persisted events
 * - Access to active session for validation
 * - Simplified persist API
 */
export class HookEventHandler {
  constructor(_deps: HookEventHandlerDeps) {
    // No deps needed - EventContext provides everything
  }

  /**
   * Handle hook triggered event - persist to event store
   */
  handleHookTriggered(ctx: EventContext, event: InternalHookTriggeredEvent): void {
    if (!ctx.active) {
      logger.debug('Skipping hook.triggered - no active session', {
        sessionId: ctx.sessionId,
        hookNames: event.hookNames,
      });
      return;
    }

    ctx.persist('hook.triggered', {
      hookNames: event.hookNames,
      hookEvent: event.hookEvent,
      toolName: event.toolName,
      toolCallId: event.toolCallId,
      timestamp: event.timestamp,
    });
  }

  /**
   * Handle hook completed event - persist to event store
   */
  handleHookCompleted(ctx: EventContext, event: InternalHookCompletedEvent): void {
    if (!ctx.active) {
      logger.debug('Skipping hook.completed - no active session', {
        sessionId: ctx.sessionId,
        hookNames: event.hookNames,
      });
      return;
    }

    ctx.persist('hook.completed', {
      hookNames: event.hookNames,
      hookEvent: event.hookEvent,
      result: event.result,
      duration: event.duration,
      reason: event.reason,
      toolName: event.toolName,
      toolCallId: event.toolCallId,
      timestamp: event.timestamp,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a HookEventHandler instance
 */
export function createHookEventHandler(deps: HookEventHandlerDeps): HookEventHandler {
  return new HookEventHandler(deps);
}
