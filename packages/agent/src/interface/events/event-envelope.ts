/**
 * @fileoverview Event envelope factory
 *
 * Centralizes event envelope creation for WebSocket broadcasts,
 * eliminating duplicate timestamp/sessionId extraction across handlers.
 */

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
