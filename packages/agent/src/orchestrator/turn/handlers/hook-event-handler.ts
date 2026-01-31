/**
 * @fileoverview Hook Event Handler - Persists Hook Lifecycle Events
 *
 * Handles hook_triggered and hook_completed events from the agent,
 * persisting them to the event store for linearized audit logging.
 */

import type { SessionId, EventType, SessionEvent as TronSessionEvent } from '../../../events/types.js';
import type { ActiveSession } from '../../types.js';
import type { HookType, HookAction } from '../../../hooks/types.js';
import { createLogger } from '../../../logging/index.js';

const logger = createLogger('hook-event-handler');

// =============================================================================
// Types
// =============================================================================

export interface HookEventHandlerDeps {
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ) => void;
  emit: (event: string, data: unknown) => void;
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
 */
export class HookEventHandler {
  private deps: HookEventHandlerDeps;

  constructor(deps: HookEventHandlerDeps) {
    this.deps = deps;
  }

  /**
   * Handle hook triggered event - persist to event store
   */
  handleHookTriggered(event: InternalHookTriggeredEvent): void {
    const session = this.deps.getActiveSession(event.sessionId);
    if (!session) {
      logger.debug('Skipping hook.triggered - session not found', {
        sessionId: event.sessionId,
        hookNames: event.hookNames,
      });
      return;
    }

    this.deps.appendEventLinearized(
      event.sessionId as SessionId,
      'hook.triggered',
      {
        hookNames: event.hookNames,
        hookEvent: event.hookEvent,
        toolName: event.toolName,
        toolCallId: event.toolCallId,
        timestamp: event.timestamp,
      },
      undefined
    );
  }

  /**
   * Handle hook completed event - persist to event store
   */
  handleHookCompleted(event: InternalHookCompletedEvent): void {
    const session = this.deps.getActiveSession(event.sessionId);
    if (!session) {
      logger.debug('Skipping hook.completed - session not found', {
        sessionId: event.sessionId,
        hookNames: event.hookNames,
      });
      return;
    }

    this.deps.appendEventLinearized(
      event.sessionId as SessionId,
      'hook.completed',
      {
        hookNames: event.hookNames,
        hookEvent: event.hookEvent,
        result: event.result,
        duration: event.duration,
        reason: event.reason,
        toolName: event.toolName,
        toolCallId: event.toolCallId,
        timestamp: event.timestamp,
      },
      undefined
    );
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
