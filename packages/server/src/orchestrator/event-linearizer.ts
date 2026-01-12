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
  type TronSessionEvent,
} from '@tron/core';
import type { ActiveSession } from './types.js';

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
 * Append an event and return the result, properly chained to the promise queue.
 *
 * Unlike `appendEventLinearized`, this function:
 * 1. Returns a Promise that resolves when the event is appended
 * 2. Returns the created event (or null if skipped/failed)
 * 3. Updates pendingHeadEventId after successful append
 *
 * Use this for synchronous-style code where you need to wait for the event
 * before continuing (e.g., endSession, switchModel, confirmCompaction).
 *
 * @param eventStore - EventStore instance for persistence
 * @param sessionId - Session ID for the event
 * @param active - Active session containing the promise chain state
 * @param type - Event type to append
 * @param payload - Event payload data
 * @returns The created event, or null if skipped due to prior error
 */
export async function appendEventLinearizedAsync(
  eventStore: EventStore,
  sessionId: SessionId,
  active: ActiveSession,
  type: EventType,
  payload: Record<string, unknown>
): Promise<TronSessionEvent | null> {
  // Wait for any pending appends to complete first
  await active.appendPromiseChain;

  // Check for prior errors
  if (active.lastAppendError) {
    logger.warn('Skipping async append due to prior error', {
      sessionId,
      type,
      priorError: active.lastAppendError.message,
    });
    return null;
  }

  const parentId = active.pendingHeadEventId;
  if (!parentId) {
    logger.error('Cannot append event: no pending head event ID', { sessionId, type });
    return null;
  }

  try {
    const event = await eventStore.append({
      sessionId,
      type,
      payload,
      parentId,
    });
    // Update in-memory head for subsequent events
    active.pendingHeadEventId = event.id;
    return event;
  } catch (err) {
    logger.error(`Failed to store ${type} event`, { err, sessionId });
    // Track error to prevent subsequent appends from creating orphaned events
    active.lastAppendError = err instanceof Error ? err : new Error(String(err));
    return null;
  }
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
