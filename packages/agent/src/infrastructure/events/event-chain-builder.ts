/**
 * @fileoverview Event Chain Builder
 *
 * Automates parentId threading for sequential event appends.
 * Tracks the current head so callers cannot forget to update it
 * or accidentally pass the wrong parent.
 */

import type { EventStore } from './event-store.js';
import type { SessionId, EventId, EventType, SessionEvent } from './types.js';

export class EventChainBuilder {
  private head: EventId;

  constructor(
    private eventStore: EventStore,
    private sessionId: SessionId,
    initialHead: EventId,
  ) {
    this.head = initialHead;
  }

  /**
   * Append an event chained from the current head.
   * Updates the head to the new event's ID.
   */
  async append(type: EventType, payload: Record<string, unknown>): Promise<SessionEvent> {
    const event = await this.eventStore.append({
      sessionId: this.sessionId,
      type,
      payload,
      parentId: this.head,
    });
    this.head = event.id;
    return event;
  }

  /**
   * Get the current head event ID.
   */
  get headEventId(): EventId {
    return this.head;
  }
}
