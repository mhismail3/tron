/**
 * @fileoverview Event Context - Scoped Context for Event Dispatch
 *
 * EventContext eliminates "shotgun surgery" when adding cross-cutting concerns
 * to event handling. Instead of manually including sessionId, timestamp, and
 * runId in every emit/persist call, handlers receive a scoped context that
 * automatically includes this metadata.
 *
 * ## Benefits
 *
 * 1. **Single session lookup**: Session resolved once at context creation
 * 2. **Consistent timestamps**: All events in one dispatch share same timestamp
 * 3. **Automatic metadata**: sessionId, timestamp, runId included automatically
 * 4. **Type safety**: Typed event types prevent typos
 * 5. **Easy testing**: createTestEventContext() provides mock context
 *
 * ## Usage
 *
 * ```typescript
 * // In coordinator (AgentEventHandler)
 * const ctx = createEventContext(sessionId, deps);
 * this.turnHandler.handleTurnStart(ctx, event);
 *
 * // In handler
 * handleTurnStart(ctx: EventContext, event: TronEvent): void {
 *   ctx.active?.sessionContext?.startTurn(event.turn);
 *   ctx.emit('agent.turn_start', { turn: event.turn });
 *   ctx.persist('stream.turn_start', { turn: event.turn });
 * }
 * ```
 */

import type { SessionId, EventType, SessionEvent as TronSessionEvent } from '../../events/types.js';
import type { ActiveSession } from '../types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Event types emitted via WebSocket to clients.
 * Using a union type prevents typos and enables IDE autocomplete.
 */
export type AgentEventType =
  | 'agent.turn_start'
  | 'agent.turn_end'
  | 'agent.text_delta'
  | 'agent.thinking_start'
  | 'agent.thinking_delta'
  | 'agent.thinking_end'
  | 'agent.tool_start'
  | 'agent.tool_end'
  | 'agent.compaction'
  | 'agent.complete'
  | 'agent.subagent_event'
  | 'agent.subagent_status'
  | 'agent.error'
  | 'agent.api_retry';

/**
 * Dependencies required to create an EventContext.
 * Injected from the coordinator (AgentEventHandler).
 */
export interface EventContextDeps {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Append event to session (fire-and-forget, linearized) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ) => void;
  /** Emit event to WebSocket clients */
  emit: (event: string, data: unknown) => void;
}

/**
 * Scoped context for a single event dispatch.
 *
 * Created at the start of forwardEvent(), passed to all handlers.
 * Provides typed methods that automatically include session metadata.
 */
export interface EventContext {
  /** Session ID this context is scoped to */
  readonly sessionId: SessionId;

  /** Timestamp captured at context creation (consistent across all events) */
  readonly timestamp: string;

  /** Current run ID (undefined if no active run) */
  readonly runId: string | undefined;

  /** Active session (may be undefined for some event types) */
  readonly active: ActiveSession | undefined;

  /**
   * Emit a real-time event to WebSocket clients.
   * Automatically includes sessionId, timestamp, runId.
   *
   * @param type - Event type (e.g., 'agent.turn_start')
   * @param data - Event-specific payload
   */
  emit(type: AgentEventType, data?: Record<string, unknown>): void;

  /**
   * Persist an event to the event store (linearized).
   * Automatically includes runId in payload.
   *
   * @param type - Event type for persistence (e.g., 'stream.turn_start')
   * @param payload - Event payload
   * @param onCreated - Optional callback when event is created (for tracking eventIds)
   */
  persist(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void;

  /**
   * Get the appendEventLinearized function for cases needing direct access.
   * Prefer using persist() when possible.
   * @deprecated Use persist() instead when possible
   */
  readonly appendEventLinearized: EventContextDeps['appendEventLinearized'];
}

// =============================================================================
// Implementation
// =============================================================================

/**
 * Implementation of EventContext.
 *
 * Captures session metadata at creation time and provides methods
 * that automatically include this metadata in all events.
 */
export class EventContextImpl implements EventContext {
  readonly sessionId: SessionId;
  readonly timestamp: string;
  readonly runId: string | undefined;
  readonly active: ActiveSession | undefined;
  readonly appendEventLinearized: EventContextDeps['appendEventLinearized'];

  private readonly deps: EventContextDeps;

  constructor(sessionId: SessionId, deps: EventContextDeps) {
    this.sessionId = sessionId;
    this.timestamp = new Date().toISOString();
    this.deps = deps;

    // Resolve session ONCE at creation
    this.active = deps.getActiveSession(sessionId);
    this.runId = this.active?.currentRunId;

    // Expose appendEventLinearized for special cases (with callbacks)
    this.appendEventLinearized = deps.appendEventLinearized;
  }

  emit(type: AgentEventType, data?: Record<string, unknown>): void {
    this.deps.emit('agent_event', {
      type,
      sessionId: this.sessionId,
      timestamp: this.timestamp,
      runId: this.runId,
      data,
    });
  }

  persist(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void {
    // Always use context's runId for consistency (overwrite any existing)
    this.deps.appendEventLinearized(
      this.sessionId,
      type,
      { ...payload, runId: this.runId },
      onCreated
    );
  }
}

// =============================================================================
// Factory Functions
// =============================================================================

/**
 * Create an EventContext for a session.
 *
 * @param sessionId - Session ID to scope the context to
 * @param deps - Dependencies (from coordinator config)
 * @returns Scoped EventContext
 */
export function createEventContext(
  sessionId: SessionId,
  deps: EventContextDeps
): EventContext {
  return new EventContextImpl(sessionId, deps);
}

// =============================================================================
// Test Helpers
// =============================================================================

/**
 * Options for creating a test EventContext.
 */
export interface TestEventContextOptions {
  sessionId: SessionId;
  runId?: string;
  timestamp?: string;
  active?: ActiveSession;
}

/**
 * Test-friendly EventContext that captures emit/persist calls.
 */
export interface TestEventContext extends EventContext {
  /** Captured emit calls for assertions */
  readonly emitCalls: Array<{ type: AgentEventType; data?: Record<string, unknown> }>;
  /** Captured persist calls for assertions */
  readonly persistCalls: Array<{ type: EventType; payload: Record<string, unknown>; onCreated?: unknown }>;
}

/**
 * Create a test EventContext with mock emit/persist.
 *
 * Usage:
 * ```typescript
 * const ctx = createTestEventContext({
 *   sessionId: 'test-123' as SessionId,
 *   runId: 'run-test',
 * });
 *
 * handler.handleEvent(ctx, event);
 *
 * expect(ctx.emitCalls).toHaveLength(1);
 * expect(ctx.emitCalls[0].type).toBe('agent.turn_start');
 * ```
 */
export function createTestEventContext(options: TestEventContextOptions): TestEventContext {
  const emitCalls: Array<{ type: AgentEventType; data?: Record<string, unknown> }> = [];
  const persistCalls: Array<{ type: EventType; payload: Record<string, unknown>; onCreated?: unknown }> = [];

  // Determine runId: explicit > from active > undefined
  const runId = options.runId !== undefined
    ? options.runId
    : options.active?.currentRunId;

  // Mock appendEventLinearized for direct access cases
  const appendEventLinearized: EventContextDeps['appendEventLinearized'] = (
    _sessionId,
    type,
    payload,
    onCreated
  ) => {
    persistCalls.push({ type, payload: { ...payload, runId }, onCreated });
  };

  const ctx: TestEventContext = {
    sessionId: options.sessionId,
    timestamp: options.timestamp ?? new Date().toISOString(),
    runId,
    active: options.active,
    emitCalls,
    persistCalls,
    appendEventLinearized,

    emit(type: AgentEventType, data?: Record<string, unknown>): void {
      emitCalls.push({ type, data });
    },

    persist(type: EventType, payload: Record<string, unknown>, onCreated?: (event: TronSessionEvent) => void): void {
      persistCalls.push({ type, payload: { ...payload, runId: ctx.runId }, onCreated });
    },
  };

  return ctx;
}
