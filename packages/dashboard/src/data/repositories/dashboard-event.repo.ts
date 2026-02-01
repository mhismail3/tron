/**
 * @fileoverview Dashboard Event Repository
 *
 * Repository for event-related queries optimized for dashboard display.
 */

import type {
  SQLiteEventStore,
  SessionId,
  EventId,
  EventType,
  SessionEvent,
} from '@tron/agent';
import type { IDashboardEventRepository } from './types.js';
import type { PaginationOptions, PaginatedResult } from '../../types/session.js';

/**
 * Repository for event queries optimized for dashboard UI
 */
export class DashboardEventRepository implements IDashboardEventRepository {
  constructor(private readonly store: SQLiteEventStore) {}

  /**
   * Get events for a session with pagination
   */
  async getEventsBySession(
    sessionId: SessionId,
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>> {
    const limit = options?.limit ?? 500;
    const offset = options?.offset ?? 0;

    const events = await this.store.getEventsBySession(sessionId, {
      limit: limit + 1, // Fetch one extra to check hasMore
      offset,
    });

    const hasMore = events.length > limit;
    const items = hasMore ? events.slice(0, limit) : events;
    const total = await this.store.countEvents(sessionId);

    return {
      items,
      total,
      limit,
      offset,
      hasMore,
    };
  }

  /**
   * Get events filtered by type
   */
  async getEventsByType(
    sessionId: SessionId,
    types: EventType[],
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>> {
    const limit = options?.limit ?? 500;
    const offset = options?.offset ?? 0;

    const events = await this.store.getEventsByType(sessionId, types, {
      limit: limit + offset + 1, // Fetch enough to handle offset and check hasMore
    });

    // Apply offset and limit manually since getEventsByType doesn't support offset
    const sliced = events.slice(offset, offset + limit + 1);
    const hasMore = sliced.length > limit;
    const items = hasMore ? sliced.slice(0, limit) : sliced;

    return {
      items,
      total: events.length,
      limit,
      offset,
      hasMore,
    };
  }

  /**
   * Get a single event by ID
   */
  async getById(eventId: EventId): Promise<SessionEvent | null> {
    return this.store.getEvent(eventId);
  }

  /**
   * Search events by text content
   */
  async search(
    sessionId: SessionId,
    query: string,
    options?: PaginationOptions
  ): Promise<PaginatedResult<SessionEvent>> {
    const limit = options?.limit ?? 100;
    const offset = options?.offset ?? 0;

    // Use the store's search functionality
    const results = await this.store.searchEvents(query, {
      sessionId,
      limit: limit + offset + 1,
    });

    // Get full events from search results
    const eventIds = results.map((r) => r.eventId);
    const eventsMap = await this.store.getEvents(eventIds);
    const allEvents = Array.from(eventsMap.values());

    // Apply offset and limit
    const sliced = allEvents.slice(offset, offset + limit + 1);
    const hasMore = sliced.length > limit;
    const items = hasMore ? sliced.slice(0, limit) : sliced;

    return {
      items,
      total: allEvents.length,
      limit,
      offset,
      hasMore,
    };
  }

  /**
   * Count events in a session
   */
  async countBySession(sessionId: SessionId): Promise<number> {
    return this.store.countEvents(sessionId);
  }
}
