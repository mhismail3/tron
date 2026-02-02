/**
 * @fileoverview Event envelope factory
 *
 * Centralizes event envelope creation for WebSocket broadcasts,
 * eliminating duplicate timestamp/sessionId extraction across handlers.
 */

// =============================================================================
// Type-Safe Broadcast Event Types
// =============================================================================

/**
 * Known broadcast event types for WebSocket events.
 * Use these constants instead of raw strings for compile-time validation.
 */
export const BroadcastEventType = {
  // Session events
  SESSION_CREATED: 'session.created',
  SESSION_ENDED: 'session.ended',
  SESSION_FORKED: 'session.forked',
  SESSION_REWOUND: 'session.rewound',

  // Agent events
  AGENT_TURN: 'agent.turn',
  AGENT_MESSAGE_DELETED: 'agent.message_deleted',
  AGENT_CONTEXT_CLEARED: 'agent.context_cleared',
  AGENT_COMPACTION: 'agent.compaction',
  AGENT_SKILL_REMOVED: 'agent.skill_removed',
  AGENT_TODOS_UPDATED: 'agent.todos_updated',

  // Browser events
  BROWSER_FRAME: 'browser.frame',
  BROWSER_CLOSED: 'browser.closed',

  // Event store events
  EVENT_NEW: 'event.new',
} as const;

/**
 * Union type of all known broadcast event types.
 * Provides compile-time validation for event type strings.
 */
export type BroadcastEventTypeValue = (typeof BroadcastEventType)[keyof typeof BroadcastEventType];

// =============================================================================
// Event Envelope
// =============================================================================

/**
 * Standard event envelope for WebSocket broadcasts
 */
export interface EventEnvelope {
  type: string;
  sessionId?: string;
  timestamp: string;
  data: unknown;
}

/**
 * Create a standardized event envelope for WebSocket broadcasts
 *
 * @param type - Event type (e.g., 'session.created', 'agent.turn')
 * @param data - Event payload data
 * @param sessionId - Optional explicit session ID (extracted from data if not provided)
 * @returns EventEnvelope with consistent structure
 *
 * @example
 * ```typescript
 * // With explicit sessionId
 * const envelope = createEventEnvelope('session.created', { name: 'test' }, 'sess_123');
 *
 * // Extract sessionId from data
 * const envelope = createEventEnvelope('agent_turn', { sessionId: 'sess_456', turn: 1 });
 *
 * // Preserve existing timestamp
 * const envelope = createEventEnvelope('event', { timestamp: existingTs, data: 'foo' });
 * ```
 */
export function createEventEnvelope(
  type: string,
  data: Record<string, unknown>,
  sessionId?: string
): EventEnvelope {
  return {
    type,
    sessionId: sessionId ?? (data.sessionId as string | undefined),
    timestamp: (data.timestamp as string | undefined) ?? new Date().toISOString(),
    data,
  };
}
