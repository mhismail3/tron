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
  /** ISO 8601 timestamp */
  timestamp: string;
}

/**
 * Agent lifecycle events
 */
export interface AgentStartEvent extends BaseTronEvent {
  type: 'agent_start';
}

export interface AgentEndEvent extends BaseTronEvent {
  type: 'agent_end';
  /** Error message if agent ended due to error */
  error?: string;
}

/**
 * Agent interrupted event - emitted when user aborts execution
 */
export interface AgentInterruptedEvent extends BaseTronEvent {
  type: 'agent_interrupted';
  /** Turn number when interrupted */
  turn: number;
  /** Partial content captured before interruption */
  partialContent?: string;
  /** Tool that was running when interrupted (if any) */
  activeTool?: string;
}

/**
 * Turn events (one turn = one LLM call + tool executions)
 */
export interface TurnStartEvent extends BaseTronEvent {
  type: 'turn_start';
  /** Turn number */
  turn: number;
}

export interface TurnEndEvent extends BaseTronEvent {
  type: 'turn_end';
  /** Turn number */
  turn: number;
  /** Duration in milliseconds */
  duration: number;
}

/**
 * Message update event (wraps stream events for agent context)
 */
export interface MessageUpdateEvent extends BaseTronEvent {
  type: 'message_update';
  /** The content delta */
  content: string;
  /** Optional stream event for additional context */
  event?: StreamEvent;
}

/**
 * Tool execution events
 */
export interface ToolExecutionStartEvent extends BaseTronEvent {
  type: 'tool_execution_start';
  toolCallId: string;
  /** Tool name */
  toolName: string;
  /** Tool arguments (optional) */
  arguments?: Record<string, unknown>;
}

export interface ToolExecutionUpdateEvent extends BaseTronEvent {
  type: 'tool_execution_update';
  toolCallId: string;
  update: string;
}

export interface ToolExecutionEndEvent extends BaseTronEvent {
  type: 'tool_execution_end';
  toolCallId: string;
  /** Tool name */
  toolName: string;
  /** Duration in milliseconds */
  duration: number;
  /** Whether the tool execution resulted in error */
  isError?: boolean;
  /** Optional detailed result */
  result?: TronToolResult;
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
  | AgentInterruptedEvent
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
    timestamp: new Date().toISOString(),
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
