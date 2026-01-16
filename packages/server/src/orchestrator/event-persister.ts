/**
 * @fileoverview EventPersister - Linearized Event Persistence
 *
 * Encapsulates the logic for appending events to the EventStore with proper
 * linearization to prevent race conditions and spurious branching.
 *
 * ## Key Invariants
 *
 * 1. Every event chains to the previous one via parentId
 * 2. Concurrent appends serialize correctly (promise chain)
 * 3. Errors stop the chain to prevent orphaned events
 * 4. pendingHeadEventId is updated synchronously AFTER each append resolves
 *
 * ## Usage
 *
 * ```typescript
 * const persister = createEventPersister({
 *   eventStore,
 *   sessionId,
 *   initialHeadEventId: session.headEventId,
 * });
 *
 * // Fire-and-forget (for streaming events)
 * persister.append('message.user', { content: 'Hello' });
 *
 * // Wait for result (for events needing the created event)
 * const event = await persister.appendAsync('message.assistant', { content: [...] });
 *
 * // Wait for all pending appends
 * await persister.flush();
 * ```
 */
import {
  createLogger,
  EventStore,
  type EventType,
  type EventId,
  type SessionId,
  type TronSessionEvent,
} from '@tron/core';

const logger = createLogger('event-persister');

// =============================================================================
// Types
// =============================================================================

export interface EventPersisterConfig {
  /** EventStore instance for persistence */
  eventStore: EventStore;
  /** Session ID for all events */
  sessionId: SessionId;
  /** Initial head event ID (from session creation or reconstruction) */
  initialHeadEventId: EventId;
}

export interface AppendRequest {
  type: EventType;
  payload: Record<string, unknown>;
  /** Optional callback invoked with the created event */
  onCreated?: (event: TronSessionEvent) => void;
}

// =============================================================================
// EventPersister Class
// =============================================================================

/**
 * Handles linearized event persistence for a single session.
 *
 * Each session should have its own EventPersister instance to ensure
 * events are chained correctly without cross-session interference.
 */
export class EventPersister {
  private readonly eventStore: EventStore;
  private readonly sessionId: SessionId;
  private pendingHead: EventId;
  private chain: Promise<void>;
  private lastError?: Error;

  constructor(config: EventPersisterConfig) {
    this.eventStore = config.eventStore;
    this.sessionId = config.sessionId;
    this.pendingHead = config.initialHeadEventId;
    this.chain = Promise.resolve();
  }

  // ===========================================================================
  // Public API
  // ===========================================================================

  /**
   * Append an event without waiting for the result (fire-and-forget).
   *
   * Use this for high-frequency events like streaming deltas where you don't
   * need the created event immediately.
   *
   * @param type - Event type
   * @param payload - Event payload
   * @param onCreated - Optional callback invoked with the created event
   */
  append(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void {
    // Skip if prior error
    if (this.lastError) {
      logger.warn('Skipping append due to prior error', {
        sessionId: this.sessionId,
        type,
        priorError: this.lastError.message,
      });
      return;
    }

    // Chain this append to the previous one
    this.chain = this.chain.then(async () => {
      // Check again inside chain - error may have occurred
      if (this.lastError) {
        logger.warn('Skipping append in chain due to prior error', {
          sessionId: this.sessionId,
          type,
          priorError: this.lastError.message,
        });
        return;
      }

      await this.doAppend(type, payload, onCreated);
    });
  }

  /**
   * Append an event and wait for the result.
   *
   * Use this when you need the created event (e.g., to track eventIds)
   * or when you need to ensure the event is persisted before continuing.
   *
   * @param type - Event type
   * @param payload - Event payload
   * @returns The created event, or null if skipped due to error
   */
  async appendAsync(
    type: EventType,
    payload: Record<string, unknown>
  ): Promise<TronSessionEvent | null> {
    // Wait for any pending appends
    await this.chain;

    // Check for prior error
    if (this.lastError) {
      logger.warn('Skipping async append due to prior error', {
        sessionId: this.sessionId,
        type,
        priorError: this.lastError.message,
      });
      return null;
    }

    return this.doAppend(type, payload);
  }

  /**
   * Append multiple events atomically (in sequence).
   *
   * Use this for operations that need multiple events to be written together,
   * like compaction (boundary + summary).
   *
   * @param requests - Array of event requests
   * @returns Array of created events (some may be null if errors occurred)
   */
  async appendMultiple(
    requests: Array<{ type: EventType; payload: Record<string, unknown> }>
  ): Promise<Array<TronSessionEvent | null>> {
    // Wait for any pending appends
    await this.chain;

    const results: Array<TronSessionEvent | null> = [];

    for (const req of requests) {
      if (this.lastError) {
        results.push(null);
        continue;
      }

      const event = await this.doAppend(req.type, req.payload);
      results.push(event);
    }

    return results;
  }

  /**
   * Wait for all pending appends to complete.
   *
   * Use this before reading from the EventStore to ensure consistency,
   * or before session deactivation to ensure all events are persisted.
   */
  async flush(): Promise<void> {
    await this.chain;
  }

  /**
   * Run an operation within the linearization chain.
   *
   * Use this for operations that need to use EventStore methods directly
   * (like deleteMessage) but still need to be properly linearized.
   *
   * The operation receives the current pending head event ID and must return
   * the new head event ID (from the event it created).
   *
   * @param operation - Async function that receives parentId and returns new event
   * @returns The event returned by the operation
   */
  async runInChain<T extends TronSessionEvent>(
    operation: (parentId: EventId) => Promise<T>
  ): Promise<T> {
    // Wait for any pending appends
    await this.chain;

    // Check for prior error
    if (this.lastError) {
      throw new Error(`Cannot run operation: prior error - ${this.lastError.message}`);
    }

    try {
      const parentId = this.pendingHead;
      const event = await operation(parentId);

      // Update head for next event
      this.pendingHead = event.id;

      return event;
    } catch (err) {
      logger.error('Failed to run linearized operation', {
        err,
        sessionId: this.sessionId,
      });

      // Track error to prevent subsequent appends
      this.lastError = err instanceof Error ? err : new Error(String(err));

      throw err;
    }
  }

  /**
   * Get the current pending head event ID.
   *
   * This is the event that the next append will chain to.
   * Updated synchronously after each successful append.
   */
  getPendingHeadEventId(): EventId {
    return this.pendingHead;
  }

  /**
   * Check if an error has occurred.
   *
   * Once an error occurs, all subsequent appends are skipped to prevent
   * orphaned events that would break the linear chain.
   */
  hasError(): boolean {
    return this.lastError !== undefined;
  }

  /**
   * Get the last error that occurred, if any.
   */
  getError(): Error | undefined {
    return this.lastError;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Actually perform the append operation.
   */
  private async doAppend(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): Promise<TronSessionEvent | null> {
    const parentId = this.pendingHead;

    try {
      const event = await this.eventStore.append({
        sessionId: this.sessionId,
        type,
        payload,
        parentId,
      });

      // Update head for next event
      this.pendingHead = event.id;

      // Invoke callback if provided
      if (onCreated) {
        onCreated(event);
      }

      return event;
    } catch (err) {
      logger.error(`Failed to append ${type} event`, {
        err,
        sessionId: this.sessionId,
      });

      // Track error to prevent subsequent appends
      this.lastError = err instanceof Error ? err : new Error(String(err));

      return null;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an EventPersister instance.
 */
export function createEventPersister(config: EventPersisterConfig): EventPersister {
  return new EventPersister(config);
}
