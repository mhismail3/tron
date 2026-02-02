/**
 * @fileoverview Hook Event Types
 *
 * Events for tracking hook lifecycle (triggered/completed).
 */

import type { BaseEvent } from './base.js';
import type { HookType, HookAction } from '@capabilities/extensions/hooks/types.js';

// =============================================================================
// Hook Triggered Event
// =============================================================================

/**
 * Emitted when a hook starts executing.
 * Used for audit trail and performance tracking.
 */
export interface HookTriggeredEvent extends BaseEvent {
  type: 'hook.triggered';
  payload: {
    /** Names of hooks being executed */
    hookNames: string[];
    /** Hook event type (PreToolUse, SessionStart, etc.) */
    hookEvent: HookType;
    /** Tool name for tool-related hooks */
    toolName?: string;
    /** Tool call ID for tool-related hooks */
    toolCallId?: string;
    /** Original timestamp from the triggering event */
    timestamp: string;
  };
}

// =============================================================================
// Hook Completed Event
// =============================================================================

/**
 * Emitted when hook execution completes.
 * Records the result and duration for auditing.
 */
export interface HookCompletedEvent extends BaseEvent {
  type: 'hook.completed';
  payload: {
    /** Names of hooks that were executed */
    hookNames: string[];
    /** Hook event type (PreToolUse, SessionStart, etc.) */
    hookEvent: HookType;
    /** Result action (continue, block, modify) */
    result: HookAction;
    /** Execution duration in milliseconds */
    duration?: number;
    /** Reason for block/modify result */
    reason?: string;
    /** Tool name for tool-related hooks */
    toolName?: string;
    /** Tool call ID for tool-related hooks */
    toolCallId?: string;
    /** Original timestamp from the triggering event */
    timestamp: string;
  };
}

// =============================================================================
// Background Hook Events
// =============================================================================

/**
 * Emitted when background hooks start executing.
 * Background hooks run fire-and-forget - the agent continues immediately.
 */
export interface HookBackgroundStartedEvent extends BaseEvent {
  type: 'hook.background_started';
  payload: {
    /** Names of background hooks being executed */
    hookNames: string[];
    /** Hook event type (PostToolUse, SessionEnd, etc.) */
    hookEvent: HookType;
    /** Unique ID to correlate started/completed events */
    executionId: string;
    /** Original timestamp */
    timestamp: string;
  };
}

/**
 * Emitted when background hook execution completes.
 * May be emitted after the agent has moved on to other operations.
 */
export interface HookBackgroundCompletedEvent extends BaseEvent {
  type: 'hook.background_completed';
  payload: {
    /** Names of background hooks that were executed */
    hookNames: string[];
    /** Hook event type (PostToolUse, SessionEnd, etc.) */
    hookEvent: HookType;
    /** Unique ID to correlate started/completed events */
    executionId: string;
    /** Result: 'continue' if all succeeded, 'error' if any failed */
    result: 'continue' | 'error';
    /** Execution duration in milliseconds */
    duration: number;
    /** Error message if result is 'error' */
    error?: string;
    /** Original timestamp */
    timestamp: string;
  };
}
