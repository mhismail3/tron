/**
 * @fileoverview Test fixtures for dashboard tests
 *
 * Provides type-safe event factories for testing. These are simplified versions
 * of the fixtures in @tron/agent for use in dashboard tests.
 */

import type {
  TronSessionEvent as SessionEvent,
  SessionStartEvent,
  UserMessageEvent,
  AssistantMessageEvent,
  ToolCallEvent,
  ToolResultEvent,
  SessionId,
  WorkspaceId,
  EventId,
} from '@tron/agent';

// =============================================================================
// ID Generators
// =============================================================================

let eventCounter = 0;

function generateEventId(): EventId {
  eventCounter++;
  return `evt_test_${eventCounter}_${Date.now()}` as unknown as EventId;
}

function generateSessionId(): SessionId {
  return `sess_test_${Date.now()}` as unknown as SessionId;
}

function generateWorkspaceId(): WorkspaceId {
  return `ws_test_${Date.now()}` as unknown as WorkspaceId;
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
  content?: Array<{ type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }>;
  turn?: number;
  model?: string;
  stopReason?: 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence';
  tokenUsage?: { inputTokens: number; outputTokens: number };
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
      model: options.model ?? 'claude-sonnet-4-20250514',
      stopReason: options.stopReason ?? 'end_turn',
      tokenUsage: options.tokenUsage ?? { inputTokens: 100, outputTokens: 50 },
    },
  };
}

// =============================================================================
// Tool Events
// =============================================================================

export interface ToolCallEventOptions extends BaseEventOptions {
  toolCallId?: string;
  name?: string;
  arguments?: Record<string, unknown>;
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
      name: options.name ?? 'TestTool',
      arguments: options.arguments ?? {},
      turn: options.turn ?? 1,
    },
  };
}

export interface ToolResultEventOptions extends BaseEventOptions {
  toolCallId?: string;
  content?: string;
  isError?: boolean;
  duration?: number;
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
      duration: options.duration ?? 100,
    },
  };
}
