/**
 * @fileoverview Repository interface definitions for the dashboard
 *
 * Defines contracts for data access that can be implemented
 * with SQLite or mocked for testing.
 */

import type { SessionId, WorkspaceId, EventId, EventType, SessionEvent } from '@tron/agent';
import type {
  DashboardSessionSummary,
  TokenUsageSummary,
  PaginationOptions,
  PaginatedResult,
  ListSessionsOptions,
  DashboardStats,
} from '../../types/session.js';
import type { TimelineEntry } from '../../types/display.js';

/**
 * Repository for session-related queries optimized for dashboard display
 */
export interface IDashboardSessionRepository {
  /**
   * List sessions with stats and optional preview
   */
  listWithStats(options?: ListSessionsOptions): Promise<DashboardSessionSummary[]>;

  /**
   * Get a single session by ID with full details
   */
  getById(sessionId: SessionId): Promise<DashboardSessionSummary | null>;

  /**
   * Get session timeline as display-ready entries
   */
  getSessionTimeline(
    sessionId: SessionId,
    options?: PaginationOptions
  ): Promise<TimelineEntry[]>;

  /**
   * Get token usage summary for a session
   */
  getTokenUsageBySession(sessionId: SessionId): Promise<TokenUsageSummary>;

  /**
   * Get dashboard-wide statistics
   */
  getStats(): Promise<DashboardStats>;

  /**
   * Count total sessions matching filters
   */
  count(options?: Pick<ListSessionsOptions, 'workspaceId' | 'ended'>): Promise<number>;
}

/**
 * Repository for event-related queries
 */
export interface IDashboardEventRepository {
  /**
   * Get events for a session with pagination
   */
  getEventsBySession(
    sessionId: SessionId,
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>>;

  /**
   * Get events filtered by type
   */
  getEventsByType(
    sessionId: SessionId,
    types: EventType[],
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>>;

  /**
   * Get a single event by ID
   */
  getById(eventId: EventId): Promise<SessionEvent | null>;

  /**
   * Search events by text content
   */
  search(
    sessionId: SessionId,
    query: string,
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>>;

  /**
   * Count events in a session
   */
  countBySession(sessionId: SessionId): Promise<number>;
}

/**
 * Combined repository facade for dashboard data access
 */
export interface IDashboardRepository {
  sessions: IDashboardSessionRepository;
  events: IDashboardEventRepository;
}
