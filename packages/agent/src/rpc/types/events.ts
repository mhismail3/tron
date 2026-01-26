/**
 * @fileoverview Event RPC Types
 *
 * Types for event operations methods.
 */

import type { EventType, SessionEvent } from '../../events/types.js';

// =============================================================================
// Event Methods
// =============================================================================

/** Get event history for a session */
export interface EventsGetHistoryParams {
  sessionId: string;
  /** Filter by event types */
  types?: EventType[];
  /** Limit number of events returned */
  limit?: number;
  /** Include events from before this event ID */
  beforeEventId?: string;
}

export interface EventsGetHistoryResult {
  events: SessionEvent[];
  hasMore: boolean;
  oldestEventId?: string;
}

/** Get events since a cursor (for sync) */
export interface EventsGetSinceParams {
  /** Session to get events from */
  sessionId?: string;
  /** Workspace to get events from (all sessions in workspace) */
  workspaceId?: string;
  /** Get events after this event ID (cursor) */
  afterEventId?: string;
  /** Get events after this timestamp */
  afterTimestamp?: string;
  /** Limit number of events */
  limit?: number;
}

export interface EventsGetSinceResult {
  events: SessionEvent[];
  /** Cursor for next request */
  nextCursor?: string;
  /** Whether more events are available */
  hasMore: boolean;
}

/** Subscribe to event stream */
export interface EventsSubscribeParams {
  /** Session IDs to subscribe to */
  sessionIds?: string[];
  /** Workspace ID to subscribe to (all sessions) */
  workspaceId?: string;
  /** Event types to filter */
  types?: EventType[];
}

export interface EventsSubscribeResult {
  subscriptionId: string;
  subscribed: boolean;
}

/** Unsubscribe from event stream */
export interface EventsUnsubscribeParams {
  subscriptionId: string;
}

export interface EventsUnsubscribeResult {
  unsubscribed: boolean;
}

/** Append a new event (for client-side event creation) */
export interface EventsAppendParams {
  sessionId: string;
  type: EventType;
  payload: Record<string, unknown>;
  /** Parent event ID (defaults to session head) */
  parentId?: string;
}

export interface EventsAppendResult {
  event: SessionEvent;
  newHeadEventId: string;
}
