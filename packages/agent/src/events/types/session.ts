/**
 * @fileoverview Session Lifecycle Events
 *
 * Events for session start, end, fork, and branch operations.
 */

import type { EventId, SessionId, BranchId } from './branded.js';
import type { BaseEvent } from './base.js';
import type { TokenUsage } from './token-usage.js';

// =============================================================================
// Session Events
// =============================================================================

/**
 * Session start event - root of a session tree
 */
export interface SessionStartEvent extends BaseEvent {
  type: 'session.start';
  payload: {
    workingDirectory: string;
    model: string;
    /** Provider (optional - can be auto-detected from model name) */
    provider?: string;
    systemPrompt?: string;
    title?: string;
    tags?: string[];
    /** If this is a fork, reference the source */
    forkedFrom?: {
      sessionId: SessionId;
      eventId: EventId;
    };
  };
}

/**
 * Session end event
 */
export interface SessionEndEvent extends BaseEvent {
  type: 'session.end';
  payload: {
    reason: 'completed' | 'aborted' | 'error' | 'timeout';
    summary?: string;
    totalTokenUsage?: TokenUsage;
    duration?: number; // milliseconds
  };
}

/**
 * Session fork event - marks a fork point
 */
export interface SessionForkEvent extends BaseEvent {
  type: 'session.fork';
  payload: {
    /** Source session we forked from */
    sourceSessionId: SessionId;
    /** Event ID we forked from */
    sourceEventId: EventId;
    /** Name for the fork */
    name?: string;
    /** Why was this forked */
    reason?: string;
  };
}

/**
 * Named branch creation
 */
export interface SessionBranchEvent extends BaseEvent {
  type: 'session.branch';
  payload: {
    branchId: BranchId;
    name: string;
    description?: string;
  };
}
