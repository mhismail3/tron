/**
 * @fileoverview Search RPC Types
 *
 * Types for search methods.
 */

import type { EventType, SessionEvent } from '../../events/types.js';

// =============================================================================
// Search Methods
// =============================================================================

/** Search content across events */
export interface SearchContentParams {
  /** Search query (FTS5 syntax supported) */
  query: string;
  /** Limit to specific workspace */
  workspaceId?: string;
  /** Limit to specific session */
  sessionId?: string;
  /** Filter by event types */
  types?: EventType[];
  /** Max results */
  limit?: number;
}

export interface SearchContentResult {
  results: Array<{
    eventId: string;
    sessionId: string;
    workspaceId: string;
    type: EventType;
    /** Highlighted snippet with matches */
    snippet: string;
    /** Relevance score */
    score: number;
    timestamp: string;
  }>;
  totalCount: number;
}

/** Search events by structured criteria */
export interface SearchEventsParams {
  /** Filter by workspace */
  workspaceId?: string;
  /** Filter by session */
  sessionId?: string;
  /** Filter by event types */
  types?: EventType[];
  /** Filter by time range - start */
  afterTimestamp?: string;
  /** Filter by time range - end */
  beforeTimestamp?: string;
  /** Text search within event content */
  contentQuery?: string;
  /** Limit results */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
}

export interface SearchEventsResult {
  events: SessionEvent[];
  totalCount: number;
  hasMore: boolean;
}
