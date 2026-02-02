/**
 * @fileoverview Event Factory
 *
 * Provides factory functions for creating properly structured events
 * with consistent ID generation, timestamp handling, and payload construction.
 * Eliminates repeated event construction boilerplate in event-store.ts.
 */

import * as crypto from 'crypto';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type EventType,
  type SessionStartEvent,
  type SessionForkEvent,
  type SessionEvent,
} from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Options for creating an event factory
 */
export interface EventFactoryOptions {
  /** Session ID for all events created by this factory */
  sessionId: SessionId;
  /** Workspace ID for all events created by this factory */
  workspaceId: WorkspaceId;
  /** Optional custom ID generator (for testing) */
  idGenerator?: () => string;
}

/**
 * Options for creating a session start event
 */
export interface SessionStartOptions {
  workingDirectory: string;
  model: string;
  provider?: string;
  title?: string;
  systemPrompt?: string;
  tags?: string[];
  /** Additional metadata to include in payload */
  metadata?: Record<string, unknown>;
}

/**
 * Options for creating a session fork event
 */
export interface SessionForkOptions {
  parentId: EventId;
  sourceSessionId: SessionId;
  sourceEventId: EventId;
  name?: string;
  reason?: string;
}

/**
 * Options for creating a generic event
 */
export interface GenericEventOptions {
  type: EventType;
  parentId: EventId | null;
  sequence: number;
  payload: Record<string, unknown>;
}

/**
 * Event factory interface
 */
export interface EventFactory {
  /** Create a session.start event */
  createSessionStart(options: SessionStartOptions): SessionStartEvent;
  /** Create a session.fork event */
  createSessionFork(options: SessionForkOptions): SessionForkEvent;
  /** Create a generic event with any type */
  createEvent(options: GenericEventOptions): SessionEvent;
  /** Generate a new event ID */
  generateEventId(): EventId;
}

// =============================================================================
// Implementation
// =============================================================================

/**
 * Default ID generator using crypto.randomUUID
 */
function defaultIdGenerator(length = 12): string {
  return crypto.randomUUID().replace(/-/g, '').slice(0, length);
}

/**
 * Create an event factory for a specific session/workspace
 *
 * @example
 * ```typescript
 * const factory = createEventFactory({
 *   sessionId: session.id,
 *   workspaceId: workspace.id,
 * });
 *
 * const startEvent = factory.createSessionStart({
 *   workingDirectory: '/path/to/project',
 *   model: 'claude-3-opus',
 * });
 * ```
 */
export function createEventFactory(options: EventFactoryOptions): EventFactory {
  const { sessionId, workspaceId, idGenerator = defaultIdGenerator } = options;

  const generateEventId = (): EventId => {
    return EventId(`evt_${idGenerator()}`);
  };

  const createTimestamp = (): string => {
    return new Date().toISOString();
  };

  return {
    generateEventId,

    createSessionStart(startOptions: SessionStartOptions): SessionStartEvent {
      const { workingDirectory, model, provider, title, systemPrompt, tags, metadata } = startOptions;

      return {
        id: generateEventId(),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: createTimestamp(),
        type: 'session.start',
        sequence: 0,
        payload: {
          workingDirectory,
          model,
          ...(provider !== undefined && { provider }),
          ...(title !== undefined && { title }),
          ...(systemPrompt !== undefined && { systemPrompt }),
          ...(tags !== undefined && { tags }),
          ...metadata,
        },
      };
    },

    createSessionFork(forkOptions: SessionForkOptions): SessionForkEvent {
      const { parentId, sourceSessionId, sourceEventId, name, reason } = forkOptions;

      return {
        id: generateEventId(),
        parentId,
        sessionId,
        workspaceId,
        timestamp: createTimestamp(),
        type: 'session.fork',
        sequence: 0,
        payload: {
          sourceSessionId,
          sourceEventId,
          ...(name !== undefined && { name }),
          ...(reason !== undefined && { reason }),
        },
      };
    },

    createEvent(eventOptions: GenericEventOptions): SessionEvent {
      const { type, parentId, sequence, payload } = eventOptions;

      return {
        id: generateEventId(),
        parentId,
        sessionId,
        workspaceId,
        timestamp: createTimestamp(),
        type,
        sequence,
        payload,
      } as SessionEvent;
    },
  };
}
