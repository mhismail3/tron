/**
 * @fileoverview Tron event types
 *
 * These types define all events emitted during agent operation.
 * Events are used for:
 * - Real-time UI updates (streaming)
 * - Logging and observability
 * - Hook system triggers
 */

import type { AssistantMessage, ToolCall } from './messages.js';
import type { TronToolResult } from './tools.js';

// =============================================================================
// LLM Stream Events (from provider)
// =============================================================================

/**
 * Stream start event
 */
export interface StreamStartEvent {
  type: 'start';
}

/**
 * Text streaming events
 */
export interface TextStartEvent {
  type: 'text_start';
}

export interface TextDeltaEvent {
  type: 'text_delta';
  delta: string;
}

export interface TextEndEvent {
  type: 'text_end';
  text: string;
  signature?: string;
}

/**
 * Thinking streaming events (Claude extended thinking)
 */
export interface ThinkingStartEvent {
  type: 'thinking_start';
}

export interface ThinkingDeltaEvent {
  type: 'thinking_delta';
  delta: string;
}

export interface ThinkingEndEvent {
  type: 'thinking_end';
  thinking: string;
  signature?: string;
}

/**
 * Tool call streaming events
 */
export interface ToolCallStartEvent {
  type: 'toolcall_start';
  toolCallId: string;
  name: string;
}

export interface ToolCallDeltaEvent {
  type: 'toolcall_delta';
  toolCallId: string;
  argumentsDelta: string;
}

export interface ToolCallEndEvent {
  type: 'toolcall_end';
  toolCall: ToolCall;
}

/**
 * Stream completion events
 */
export interface DoneEvent {
  type: 'done';
  message: AssistantMessage;
  stopReason: string;
}

export interface ErrorEvent {
  type: 'error';
  error: Error;
}

/**
 * Union of all LLM stream events
 */
export type StreamEvent =
  | StreamStartEvent
  | TextStartEvent
  | TextDeltaEvent
  | TextEndEvent
  | ThinkingStartEvent
  | ThinkingDeltaEvent
  | ThinkingEndEvent
  | ToolCallStartEvent
  | ToolCallDeltaEvent
  | ToolCallEndEvent
  | DoneEvent
  | ErrorEvent;

// =============================================================================
// Tron Agent Events
// =============================================================================

/**
 * Base event interface with common fields
 */
export interface BaseTronEvent {
  sessionId: string;
  timestamp: number;
}

/**
 * Agent lifecycle events
 */
export interface AgentStartEvent extends BaseTronEvent {
  type: 'agent_start';
}

export interface AgentEndEvent extends BaseTronEvent {
  type: 'agent_end';
}

/**
 * Turn events (one turn = one LLM call + tool executions)
 */
export interface TurnStartEvent extends BaseTronEvent {
  type: 'turn_start';
}

export interface TurnEndEvent extends BaseTronEvent {
  type: 'turn_end';
}

/**
 * Message update event (wraps stream events for agent context)
 */
export interface MessageUpdateEvent extends BaseTronEvent {
  type: 'message_update';
  event: StreamEvent;
}

/**
 * Tool execution events
 */
export interface ToolExecutionStartEvent extends BaseTronEvent {
  type: 'tool_execution_start';
  toolCallId: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface ToolExecutionUpdateEvent extends BaseTronEvent {
  type: 'tool_execution_update';
  toolCallId: string;
  update: string;
}

export interface ToolExecutionEndEvent extends BaseTronEvent {
  type: 'tool_execution_end';
  toolCallId: string;
  result: TronToolResult;
}

/**
 * Hook events
 */
export interface HookTriggeredEvent extends BaseTronEvent {
  type: 'hook_triggered';
  hookName: string;
  hookEvent: string;
}

export interface HookCompletedEvent extends BaseTronEvent {
  type: 'hook_completed';
  hookName: string;
  hookEvent: string;
  result: 'continue' | 'block' | 'modify';
}

/**
 * Session events
 */
export interface SessionSavedEvent extends BaseTronEvent {
  type: 'session_saved';
  filePath: string;
}

export interface SessionLoadedEvent extends BaseTronEvent {
  type: 'session_loaded';
  filePath: string;
  messageCount: number;
}

/**
 * Context events
 */
export interface ContextWarningEvent extends BaseTronEvent {
  type: 'context_warning';
  usagePercent: number;
  message: string;
}

/**
 * Error event
 */
export interface TronErrorEvent extends BaseTronEvent {
  type: 'error';
  error: Error;
  context?: string;
}

/**
 * Union of all Tron agent events
 */
export type TronEvent =
  | AgentStartEvent
  | AgentEndEvent
  | TurnStartEvent
  | TurnEndEvent
  | MessageUpdateEvent
  | ToolExecutionStartEvent
  | ToolExecutionUpdateEvent
  | ToolExecutionEndEvent
  | HookTriggeredEvent
  | HookCompletedEvent
  | SessionSavedEvent
  | SessionLoadedEvent
  | ContextWarningEvent
  | TronErrorEvent;

/**
 * All Tron event types as a union
 */
export type TronEventType = TronEvent['type'];

// =============================================================================
// Type Guards
// =============================================================================

export function isStreamEvent(event: StreamEvent | TronEvent): event is StreamEvent {
  return [
    'start', 'text_start', 'text_delta', 'text_end',
    'thinking_start', 'thinking_delta', 'thinking_end',
    'toolcall_start', 'toolcall_delta', 'toolcall_end',
    'done', 'error'
  ].includes(event.type);
}

export function isTronEvent(event: StreamEvent | TronEvent): event is TronEvent {
  return 'sessionId' in event && 'timestamp' in event;
}

export function isToolExecutionEvent(
  event: TronEvent
): event is ToolExecutionStartEvent | ToolExecutionUpdateEvent | ToolExecutionEndEvent {
  return event.type.startsWith('tool_execution');
}

// =============================================================================
// Event Factory Helpers
// =============================================================================

/**
 * Create a base event with sessionId and timestamp
 */
export function createBaseEvent(sessionId: string): BaseTronEvent {
  return {
    sessionId,
    timestamp: Date.now(),
  };
}

/**
 * Create an agent start event
 */
export function agentStartEvent(sessionId: string): AgentStartEvent {
  return {
    type: 'agent_start',
    ...createBaseEvent(sessionId),
  };
}

/**
 * Create an agent end event
 */
export function agentEndEvent(sessionId: string): AgentEndEvent {
  return {
    type: 'agent_end',
    ...createBaseEvent(sessionId),
  };
}
