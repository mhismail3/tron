/**
 * @fileoverview Event Linearization Utilities
 *
 * Provides promise chain-based serialization for event appends to prevent
 * race conditions and spurious branching in the event tree.
 *
 * The key insight: parentId is captured INSIDE the .then() callback,
 * which only runs AFTER the previous event's promise resolves.
 * This ensures each event correctly chains to the previous one.
 */
import {
  createLogger,
  EventStore,
  type EventType,
  type SessionId,
} from '@tron/core';
import type { ActiveSession } from './types';

const logger = createLogger('event-linearizer');

/**
 * Append an event using the session's promise chain to ensure linearization.
 *
 * CRITICAL: This solves the spurious branching bug where rapid events
 * A, B, C all capture the same parentId before any updates.
 *
 * @param eventStore - EventStore instance for persistence
 * @param sessionId - Session ID for the event
 * @param active - Active session containing the promise chain state
 * @param type - Event type to append
 * @param payload - Event payload data
 */
export function appendEventLinearized(
  eventStore: EventStore,
  sessionId: SessionId,
  active: ActiveSession,
  type: EventType,
  payload: Record<string, unknown>
): void {
  // P0 FIX: Skip appends if prior append failed to prevent malformed event trees
  // If turn_start fails but turn_end succeeds, the tree becomes inconsistent
  if (active.lastAppendError) {
    logger.warn('Skipping append due to prior error', {
      sessionId,
      type,
      priorError: active.lastAppendError.message,
    });
    return;
  }

  if (!active.pendingHeadEventId) {
    logger.error('Cannot append event: no pending head event ID', { sessionId, type });
    return;
  }

  // Chain this append to the previous one
  // CRITICAL: parentId must be captured INSIDE .then() to get updated value
  active.appendPromiseChain = active.appendPromiseChain
    .then(async () => {
      // Check again inside chain - error may have occurred in previous chain link
      if (active.lastAppendError) {
        logger.warn('Skipping append in chain due to prior error', {
          sessionId,
          type,
          priorError: active.lastAppendError.message,
        });
        return;
      }

      // Capture parent ID HERE - after previous event has updated pendingHeadEventId
      const parentId = active.pendingHeadEventId;
      if (!parentId) {
        logger.error('Cannot append event: no pending head event ID in chain', { sessionId, type });
        return;
      }

      try {
        const event = await eventStore.append({
          sessionId,
          type,
          payload,
          parentId,
        });
        // Update in-memory head for the next event in the chain
        active.pendingHeadEventId = event.id;
      } catch (err) {
        logger.error(`Failed to store ${type} event`, { err, sessionId });
        // P0 FIX: Track error to prevent subsequent appends from creating orphaned events
        active.lastAppendError = err instanceof Error ? err : new Error(String(err));
      }
    });
}

/**
 * Wait for all pending event appends to complete for a session.
 * Useful for tests and ensuring DB state is consistent before queries.
 */
export async function flushPendingEvents(active: ActiveSession): Promise<void> {
  await active.appendPromiseChain;
}

/**
 * Flush pending events for multiple sessions.
 */
export async function flushAllPendingEvents(sessions: Iterable<ActiveSession>): Promise<void> {
  const flushes = Array.from(sessions).map(s => s.appendPromiseChain);
  await Promise.all(flushes);
}
