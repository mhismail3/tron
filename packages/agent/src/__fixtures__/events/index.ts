/**
 * @fileoverview Type-safe event factories for testing
 *
 * Provides factory functions for creating properly typed SessionEvent objects
 * for use in tests. Eliminates ad-hoc event creation patterns scattered across test files.
 *
 * @example
 * ```typescript
 * import { createSessionStartEvent, createUserMessageEvent, createToolCallEvent } from '../__fixtures__/events/index.js';
 *
 * const events = [
 *   createSessionStartEvent(),
 *   createUserMessageEvent({ content: 'Hello' }),
 *   createAssistantMessageEvent({ content: [{ type: 'text', text: 'Hi!' }] }),
 * ];
 * ```
 */

import type {
  SessionEvent,
  SessionStartEvent,
  SessionEndEvent,
  SessionForkEvent,
  UserMessageEvent,
  AssistantMessageEvent,
  ToolCallEvent,
  ToolResultEvent,
  ConfigModelSwitchEvent,
  MessageDeletedEvent,
  CompactBoundaryEvent,
  StreamTurnStartEvent,
  StreamTurnEndEvent,
  EventId,
  SessionId,
  WorkspaceId,
  ContentBlock,
} from '../../events/types.js';

// =============================================================================
// ID Generators
// =============================================================================

let eventCounter = 0;

function generateEventId(): EventId {
  eventCounter++;
  return `evt_test_${eventCounter}_${Date.now()}` as EventId;
}

function generateSessionId(): SessionId {
  return `sess_test_${Date.now()}` as SessionId;
}

function generateWorkspaceId(): WorkspaceId {
  return `ws_test_${Date.now()}` as WorkspaceId;
}

// =============================================================================
// Base Event Options
// =============================================================================

interface BaseEventOptions {
  id?: EventId;
  parentId?: EventId | null;
  sessionId?: SessionId;
  workspaceId?: WorkspaceId;
  timestamp?: string;
  sequence?: number;
}

// =============================================================================
// Session Events
// =============================================================================

export interface SessionStartEventOptions extends BaseEventOptions {
  workingDirectory?: string;
  model?: string;
  provider?: string;
  title?: string;
}

export function createSessionStartEvent(options: SessionStartEventOptions = {}): SessionStartEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'session.start',
    sequence: options.sequence ?? 0,
    payload: {
      workingDirectory: options.workingDirectory ?? '/test/project',
      model: options.model ?? 'claude-sonnet-4-20250514',
      provider: options.provider,
      title: options.title,
    },
  };
}

export interface SessionEndEventOptions extends BaseEventOptions {
  reason?: 'user_request' | 'timeout' | 'error' | 'completed';
}

export function createSessionEndEvent(options: SessionEndEventOptions = {}): SessionEndEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'session.end',
    sequence: options.sequence ?? 0,
    payload: {
      reason: options.reason,
    },
  };
}

export interface SessionForkEventOptions extends BaseEventOptions {
  sourceSessionId?: SessionId;
  sourceEventId?: EventId;
  name?: string;
}

export function createSessionForkEvent(options: SessionForkEventOptions = {}): SessionForkEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'session.fork',
    sequence: options.sequence ?? 0,
    payload: {
      sourceSessionId: options.sourceSessionId ?? generateSessionId(),
      sourceEventId: options.sourceEventId ?? generateEventId(),
      name: options.name,
    },
  };
}

// =============================================================================
// Message Events
// =============================================================================

export interface UserMessageEventOptions extends BaseEventOptions {
  content?: string;
  turn?: number;
}

export function createUserMessageEvent(options: UserMessageEventOptions = {}): UserMessageEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'message.user',
    sequence: options.sequence ?? 0,
    payload: {
      content: options.content ?? 'Test user message',
      turn: options.turn ?? 1,
    },
  };
}

export interface AssistantMessageEventOptions extends BaseEventOptions {
  content?: ContentBlock[];
  turn?: number;
  model?: string;
  stopReason?: string;
}

export function createAssistantMessageEvent(options: AssistantMessageEventOptions = {}): AssistantMessageEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'message.assistant',
    sequence: options.sequence ?? 0,
    payload: {
      content: options.content ?? [{ type: 'text', text: 'Test assistant response' }],
      turn: options.turn ?? 1,
      model: options.model,
      stopReason: options.stopReason,
    },
  };
}

// =============================================================================
// Tool Events
// =============================================================================

export interface ToolCallEventOptions extends BaseEventOptions {
  toolCallId?: string;
  toolName?: string;
  input?: Record<string, unknown>;
  turn?: number;
}

export function createToolCallEvent(options: ToolCallEventOptions = {}): ToolCallEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'tool.call',
    sequence: options.sequence ?? 0,
    payload: {
      toolCallId: options.toolCallId ?? `call_${Date.now()}`,
      toolName: options.toolName ?? 'TestTool',
      input: options.input ?? {},
      turn: options.turn ?? 1,
    },
  };
}

export interface ToolResultEventOptions extends BaseEventOptions {
  toolCallId?: string;
  content?: string | Array<{ type: string; text?: string }>;
  isError?: boolean;
}

export function createToolResultEvent(options: ToolResultEventOptions = {}): ToolResultEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'tool.result',
    sequence: options.sequence ?? 0,
    payload: {
      toolCallId: options.toolCallId ?? `call_${Date.now()}`,
      content: options.content ?? 'Tool result content',
      isError: options.isError ?? false,
    },
  };
}

// =============================================================================
// Config Events
// =============================================================================

export interface ConfigModelSwitchEventOptions extends BaseEventOptions {
  previousModel?: string;
  newModel?: string;
  provider?: string;
}

export function createConfigModelSwitchEvent(options: ConfigModelSwitchEventOptions = {}): ConfigModelSwitchEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'config.model_switch',
    sequence: options.sequence ?? 0,
    payload: {
      previousModel: options.previousModel ?? 'claude-sonnet-4-20250514',
      newModel: options.newModel ?? 'claude-3-5-sonnet-20241022',
      provider: options.provider,
    },
  };
}

// =============================================================================
// Message Operations Events
// =============================================================================

export interface MessageDeletedEventOptions extends BaseEventOptions {
  targetEventId?: EventId;
  targetType?: 'message.user' | 'message.assistant';
  targetTurn?: number;
  reason?: 'user_request' | 'content_policy' | 'context_management';
}

export function createMessageDeletedEvent(options: MessageDeletedEventOptions = {}): MessageDeletedEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'message.deleted',
    sequence: options.sequence ?? 0,
    payload: {
      targetEventId: options.targetEventId ?? generateEventId(),
      targetType: options.targetType ?? 'message.user',
      targetTurn: options.targetTurn,
      reason: options.reason ?? 'user_request',
    },
  };
}

// =============================================================================
// Compaction Events
// =============================================================================

export interface CompactBoundaryEventOptions extends BaseEventOptions {
  boundaryEventId?: EventId;
  tokensBefore?: number;
  tokensAfter?: number;
}

export function createCompactBoundaryEvent(options: CompactBoundaryEventOptions = {}): CompactBoundaryEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'compact.boundary',
    sequence: options.sequence ?? 0,
    payload: {
      boundaryEventId: options.boundaryEventId ?? generateEventId(),
      tokensBefore: options.tokensBefore ?? 10000,
      tokensAfter: options.tokensAfter ?? 2000,
    },
  };
}

// =============================================================================
// Streaming Events
// =============================================================================

export interface StreamTurnStartEventOptions extends BaseEventOptions {
  turn?: number;
  model?: string;
}

export function createStreamTurnStartEvent(options: StreamTurnStartEventOptions = {}): StreamTurnStartEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'stream.turn_start',
    sequence: options.sequence ?? 0,
    payload: {
      turn: options.turn ?? 1,
      model: options.model ?? 'claude-sonnet-4-20250514',
    },
  };
}

export interface StreamTurnEndEventOptions extends BaseEventOptions {
  turn?: number;
  tokenUsage?: { inputTokens: number; outputTokens: number };
  stopReason?: string;
}

export function createStreamTurnEndEvent(options: StreamTurnEndEventOptions = {}): StreamTurnEndEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: 'stream.turn_end',
    sequence: options.sequence ?? 0,
    payload: {
      turn: options.turn ?? 1,
      tokenUsage: options.tokenUsage ?? { inputTokens: 100, outputTokens: 50 },
      stopReason: options.stopReason ?? 'end_turn',
    },
  };
}

// =============================================================================
// Generic Event Factory
// =============================================================================

/**
 * Create a generic SessionEvent - useful for testing with minimal type constraints.
 * For production tests, prefer the typed factories above.
 */
export function createGenericEvent<T extends SessionEvent['type']>(
  type: T,
  payload: Record<string, unknown>,
  options: BaseEventOptions = {}
): SessionEvent {
  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId: options.sessionId ?? generateSessionId(),
    workspaceId: options.workspaceId ?? generateWorkspaceId(),
    timestamp: options.timestamp ?? new Date().toISOString(),
    type,
    sequence: options.sequence ?? 0,
    payload,
  } as SessionEvent;
}

// =============================================================================
// Event Chain Builders
// =============================================================================

/**
 * Create a chain of events with proper parent links.
 * Useful for testing event ancestry and reconstruction.
 */
export function createEventChain(events: SessionEvent[]): SessionEvent[] {
  if (events.length === 0) return [];

  const sessionId = events[0].sessionId;
  const workspaceId = events[0].workspaceId;

  return events.map((event, index) => ({
    ...event,
    sessionId,
    workspaceId,
    parentId: index === 0 ? null : events[index - 1].id,
    sequence: index,
  }));
}

/**
 * Create a basic conversation chain: session.start → user → assistant
 */
export function createBasicConversationChain(options: {
  userContent?: string;
  assistantContent?: string;
  sessionId?: SessionId;
  workspaceId?: WorkspaceId;
} = {}): SessionEvent[] {
  const sessionId = options.sessionId ?? generateSessionId();
  const workspaceId = options.workspaceId ?? generateWorkspaceId();

  const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
  const user = createUserMessageEvent({
    sessionId,
    workspaceId,
    parentId: start.id,
    sequence: 1,
    content: options.userContent ?? 'Hello',
    turn: 1,
  });
  const assistant = createAssistantMessageEvent({
    sessionId,
    workspaceId,
    parentId: user.id,
    sequence: 2,
    content: [{ type: 'text', text: options.assistantContent ?? 'Hi there!' }],
    turn: 1,
  });

  return [start, user, assistant];
}

/**
 * Create a tool use conversation chain: session.start → user → assistant (with tool_use) → tool.result → assistant
 */
export function createToolUseChain(options: {
  userContent?: string;
  toolName?: string;
  toolInput?: Record<string, unknown>;
  toolResult?: string;
  finalAssistantContent?: string;
  sessionId?: SessionId;
  workspaceId?: WorkspaceId;
} = {}): SessionEvent[] {
  const sessionId = options.sessionId ?? generateSessionId();
  const workspaceId = options.workspaceId ?? generateWorkspaceId();
  const toolCallId = `call_${Date.now()}`;

  const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
  const user = createUserMessageEvent({
    sessionId,
    workspaceId,
    parentId: start.id,
    sequence: 1,
    content: options.userContent ?? 'Use a tool',
    turn: 1,
  });
  const assistantWithTool = createAssistantMessageEvent({
    sessionId,
    workspaceId,
    parentId: user.id,
    sequence: 2,
    content: [
      { type: 'text', text: 'I will use a tool.' },
      {
        type: 'tool_use',
        id: toolCallId,
        name: options.toolName ?? 'TestTool',
        input: options.toolInput ?? {},
      },
    ],
    turn: 1,
  });
  const toolResult = createToolResultEvent({
    sessionId,
    workspaceId,
    parentId: assistantWithTool.id,
    sequence: 3,
    toolCallId,
    content: options.toolResult ?? 'Tool completed successfully',
  });
  const finalAssistant = createAssistantMessageEvent({
    sessionId,
    workspaceId,
    parentId: toolResult.id,
    sequence: 4,
    content: [{ type: 'text', text: options.finalAssistantContent ?? 'Done!' }],
    turn: 2,
  });

  return [start, user, assistantWithTool, toolResult, finalAssistant];
}
