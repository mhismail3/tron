/**
 * @fileoverview EventController - Event Query and Mutation Operations
 *
 * Consolidates all event operations from the orchestrator with proper
 * linearization for active sessions.
 *
 * ## Key Responsibilities
 *
 * 1. **Query Operations** - Read-only access to session events
 *    - getState: Session state at head or specific event
 *    - getMessages: Reconstructed messages at head or specific event
 *    - getEvents: All events for a session
 *    - getAncestors: Ancestor chain for an event
 *    - search: Full-text search across events
 *
 * 2. **Mutation Operations** - Event appending with linearization
 *    - append: Append event (linearized for active sessions)
 *    - deleteMessage: Delete message (linearized for active sessions)
 *
 * 3. **Flush Operations** - Wait for pending event persistence
 *    - flush: Flush single session
 *    - flushAll: Flush all active sessions
 *
 * ## Linearization
 *
 * For active sessions (with running agent), event appends go through
 * SessionContext to maintain proper event chain ordering. This prevents
 * the "orphaned branch" bug where out-of-band events get skipped.
 *
 * For inactive sessions, direct EventStore append is used since no
 * concurrent operations are possible.
 */
import type { EventStore, AppendEventOptions, SearchOptions } from '@infrastructure/events/event-store.js';
import type {
  SessionEvent,
  SessionState,
  Message,
  EventId,
  SessionId,
  WorkspaceId,
  EventType,
  SearchResult,
} from '@infrastructure/events/types.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';

// =============================================================================
// Types
// =============================================================================

export interface EventControllerConfig {
  /** EventStore instance for persistence */
  eventStore: EventStore;
  /** Active session store */
  sessionStore: ActiveSessionStore;
  /** Optional callback when an event is created */
  onEventCreated?: (event: SessionEvent, sessionId: string) => void;
}

export interface EventSearchOptions {
  workspaceId?: string;
  sessionId?: string;
  types?: string[];
  limit?: number;
}

export interface DeleteMessageResult {
  id: string;
  payload: unknown;
}

// =============================================================================
// EventController Class
// =============================================================================

/**
 * Controller for event query and mutation operations.
 *
 * Provides linearized event appending for active sessions to maintain
 * proper event chain ordering and prevent orphaned branches.
 */
export class EventController {
  private readonly eventStore: EventStore;
  private readonly sessionStore: ActiveSessionStore;
  private readonly onEventCreated?: (event: SessionEvent, sessionId: string) => void;

  constructor(config: EventControllerConfig) {
    this.eventStore = config.eventStore;
    this.sessionStore = config.sessionStore;
    this.onEventCreated = config.onEventCreated;
  }

  // ===========================================================================
  // Query Operations
  // ===========================================================================

  /**
   * Get session state at head or specific event.
   *
   * @param sessionId - Session ID
   * @param atEventId - Optional event ID to get state at (defaults to head)
   * @returns Session state including model, settings, etc.
   */
  async getState(sessionId: string, atEventId?: string): Promise<SessionState> {
    if (atEventId) {
      return this.eventStore.getStateAt(atEventId as EventId);
    }
    return this.eventStore.getStateAtHead(sessionId as SessionId);
  }

  /**
   * Get reconstructed messages at head or specific event.
   *
   * @param sessionId - Session ID
   * @param atEventId - Optional event ID to get messages at (defaults to head)
   * @returns Array of reconstructed messages
   */
  async getMessages(sessionId: string, atEventId?: string): Promise<Message[]> {
    if (atEventId) {
      return this.eventStore.getMessagesAt(atEventId as EventId);
    }
    return this.eventStore.getMessagesAtHead(sessionId as SessionId);
  }

  /**
   * Get all events for a session.
   *
   * @param sessionId - Session ID
   * @returns Array of all session events
   */
  async getEvents(sessionId: string): Promise<SessionEvent[]> {
    return this.eventStore.getEventsBySession(sessionId as SessionId);
  }

  /**
   * Get ancestor chain for an event.
   *
   * Walks from the event back to the root, returning all events in the chain.
   *
   * @param eventId - Event ID to get ancestors for
   * @returns Array of events from eventId back to root
   */
  async getAncestors(eventId: string): Promise<SessionEvent[]> {
    return this.eventStore.getAncestors(eventId as EventId);
  }

  /**
   * Search events by query string.
   *
   * @param query - Search query
   * @param options - Optional filters (workspaceId, sessionId, types, limit)
   * @returns Array of search results with snippets and scores
   */
  async search(query: string, options?: EventSearchOptions): Promise<SearchResult[]> {
    const searchOptions: SearchOptions | undefined = options ? {
      workspaceId: options.workspaceId as WorkspaceId | undefined,
      sessionId: options.sessionId as SessionId | undefined,
      types: options.types as EventType[] | undefined,
      limit: options.limit,
    } : undefined;

    return this.eventStore.search(query, searchOptions);
  }

  // ===========================================================================
  // Mutation Operations
  // ===========================================================================

  /**
   * Append an event to a session.
   *
   * CRITICAL: For active sessions, this uses SessionContext for linearized
   * append to maintain proper event chain ordering. This prevents the
   * "orphaned branch" bug where out-of-band events get skipped.
   *
   * For inactive sessions, uses direct EventStore append.
   *
   * @param options - Append options including sessionId, type, payload, parentId
   * @returns The created event
   * @throws If linearized append fails for active session
   */
  async append(options: AppendEventOptions): Promise<SessionEvent> {
    const active = this.sessionStore.get(options.sessionId);
    let event: SessionEvent;

    if (active) {
      // CRITICAL: For active sessions, use SessionContext for linearized append
      const linearizedEvent = await active.sessionContext.appendEvent(
        options.type,
        options.payload
      );

      if (!linearizedEvent) {
        throw new Error(`Failed to append ${options.type} event (linearized append returned null)`);
      }
      event = linearizedEvent;
    } else {
      // For inactive sessions, direct append is safe
      event = await this.eventStore.append(options);
    }

    // Notify listeners
    if (this.onEventCreated) {
      this.onEventCreated(event, options.sessionId);
    }

    return event;
  }

  /**
   * Delete a message from a session.
   *
   * Appends a message.deleted event to the event log. The original message
   * is preserved but will be filtered out during reconstruction.
   *
   * CRITICAL: Uses SessionContext's linearized append for active sessions.
   *
   * @param sessionId - Session ID
   * @param targetEventId - Event ID of the message to delete
   * @param reason - Optional deletion reason
   * @returns The deletion event
   */
  async deleteMessage(
    sessionId: string,
    targetEventId: string,
    reason?: 'user_request' | 'content_policy' | 'context_management'
  ): Promise<SessionEvent> {
    const active = this.sessionStore.get(sessionId);
    let deletionEvent: SessionEvent;

    if (active?.sessionContext) {
      // CRITICAL: For active sessions, use SessionContext's linearization chain
      deletionEvent = await active.sessionContext.runInChain(async () => {
        return this.eventStore.deleteMessage(
          sessionId as SessionId,
          targetEventId as EventId,
          reason
        );
      });
    } else {
      // Session not active - direct call is safe
      deletionEvent = await this.eventStore.deleteMessage(
        sessionId as SessionId,
        targetEventId as EventId,
        reason
      );
    }

    // Notify listeners
    if (this.onEventCreated) {
      this.onEventCreated(deletionEvent, sessionId);
    }

    return deletionEvent;
  }

  // ===========================================================================
  // Flush Operations
  // ===========================================================================

  /**
   * Wait for all pending event appends to complete for a session.
   *
   * Useful for tests and ensuring DB state is consistent before queries.
   *
   * @param sessionId - Session ID to flush
   */
  async flush(sessionId: string): Promise<void> {
    const active = this.sessionStore.get(sessionId);
    if (active?.sessionContext) {
      await active.sessionContext.flushEvents();
    }
  }

  /**
   * Flush all active sessions' pending events.
   */
  async flushAll(): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const [, active] of this.sessionStore.entries()) {
      if (active.sessionContext) {
        promises.push(active.sessionContext.flushEvents());
      }
    }
    await Promise.all(promises);
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an EventController instance.
 */
export function createEventController(config: EventControllerConfig): EventController {
  return new EventController(config);
}
