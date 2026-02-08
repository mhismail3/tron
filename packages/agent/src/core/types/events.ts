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
import type { TokenRecord } from '@infrastructure/tokens/index.js';

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
 * Retry event - emitted when a retryable error occurs and we're about to retry
 */
export interface RetryEvent {
  type: 'retry';
  /** Current attempt number (1-based) */
  attempt: number;
  /** Maximum number of retries configured */
  maxRetries: number;
  /** Delay before next retry in milliseconds */
  delayMs: number;
  /** Parsed error that triggered the retry */
  error: {
    category: string;
    message: string;
    isRetryable: boolean;
  };
}

/**
 * Safety block event - emitted when response is blocked by safety filters
 * (Specific to Gemini/Google provider)
 */
export interface SafetyBlockEvent {
  type: 'safety_block';
  /** Categories that triggered the safety block */
  blockedCategories: string[];
  /** Error describing the safety block */
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
  | ErrorEvent
  | RetryEvent
  | SafetyBlockEvent;

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
 * Agent ready event - emitted after background hooks (compaction, memory) complete.
 * iOS uses this to re-enable the send button after post-processing.
 */
export interface AgentReadyEvent extends BaseTronEvent {
  type: 'agent_ready';
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
  /** Token usage for this turn (per-turn values from LLM response) */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
    /** Tokens read from prompt cache (billed at discounted rate) */
    cacheReadTokens?: number;
    /** Tokens written to prompt cache (billed at premium rate) */
    cacheCreationTokens?: number;
  };
  /**
   * Immutable token record with source (raw provider values), computed (normalized), and metadata.
   * The canonical token data structure for cross-platform consistency.
   */
  tokenRecord?: TokenRecord;
  /** Cost for this turn in USD */
  cost?: number;
  /** Current model's context window limit (for iOS sync after model switch) */
  contextLimit?: number;
}

/**
 * Turn failed event - emitted when a turn fails due to errors
 *
 * This event ensures iOS receives visibility into failures that would
 * otherwise cause the agent to stop silently.
 */
export interface TurnFailedEvent extends BaseTronEvent {
  type: 'agent.turn_failed';
  /** Turn number that failed */
  turn: number;
  /** Human-readable error message */
  error: string;
  /** Error category code (e.g., 'PAUTH', 'PRATE', 'NET', 'CTX') */
  code?: string;
  /** Human-readable error category */
  category?: string;
  /** Whether the user can retry this operation */
  recoverable: boolean;
  /** Any content generated before the failure occurred */
  partialContent?: string;
}

/**
 * Response complete event - emitted when LLM API response finishes streaming,
 * BEFORE tool execution begins. This provides token usage data at the earliest
 * possible moment, allowing normalization before message.assistant is created.
 *
 * This is a critical event for proper token tracking architecture:
 * - Fires immediately after streaming completes (message_stop from provider)
 * - Contains the full token usage from the API response
 * - Triggers TokenRecord computation
 * - Enables message.assistant to include token data even for tool-using turns
 */
export interface ResponseCompleteEvent extends BaseTronEvent {
  type: 'response_complete';
  /** Turn number */
  turn: number;
  /** Stop reason from LLM (end_turn, tool_use, max_tokens, etc.) */
  stopReason: string;
  /** Raw token usage from provider API */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  };
  /** Whether the response contains tool calls */
  hasToolCalls: boolean;
  /** Number of tool calls in the response */
  toolCallCount: number;
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
/**
 * Tool use batch event - emitted BEFORE tool execution with ALL tool_use blocks
 * from the model's response. This allows tracking all tool intents before execution starts.
 */
export interface ToolUseBatchEvent extends BaseTronEvent {
  type: 'tool_use_batch';
  /** All tool_use blocks from the model's response */
  toolCalls: Array<{
    id: string;
    name: string;
    arguments: Record<string, unknown>;
  }>;
}

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
 * Tool call argument delta event - emitted during streaming when
 * tool call arguments are being streamed from the LLM.
 * Used for progressive UI rendering of tools like RenderAppUI.
 */
export interface ToolCallArgumentDeltaEvent extends BaseTronEvent {
  type: 'toolcall_delta';
  /** Tool call ID */
  toolCallId: string;
  /** Tool name (if known) */
  toolName?: string;
  /** Partial JSON arguments delta */
  argumentsDelta: string;
}

/**
 * Tool call generating event - emitted at toolcall_start time,
 * BEFORE arguments are streamed. Allows the UI to show a spinning
 * tool chip immediately instead of waiting for tool execution.
 *
 * This is ephemeral (not persisted) — it bridges the gap between
 * the LLM starting to generate a tool call and tool_execution_start.
 */
export interface ToolCallGeneratingEvent extends BaseTronEvent {
  type: 'toolcall_generating';
  /** Tool call ID */
  toolCallId: string;
  /** Tool name */
  toolName: string;
}

/**
 * Hook events
 */
export interface HookTriggeredEvent extends BaseTronEvent {
  type: 'hook_triggered';
  /** Names of hooks being executed */
  hookNames: string[];
  /** Hook event type (PreToolUse, SessionStart, etc.) */
  hookEvent: string;
  /** Tool name for tool-related hooks */
  toolName?: string;
  /** Tool call ID for tool-related hooks */
  toolCallId?: string;
}

export interface HookCompletedEvent extends BaseTronEvent {
  type: 'hook_completed';
  /** Names of hooks that were executed */
  hookNames: string[];
  /** Hook event type (PreToolUse, SessionStart, etc.) */
  hookEvent: string;
  /** Result action (continue, block, modify) */
  result: 'continue' | 'block' | 'modify';
  /** Execution duration in milliseconds */
  duration?: number;
  /** Reason for block/modify result */
  reason?: string;
  /** Tool name for tool-related hooks */
  toolName?: string;
  /** Tool call ID for tool-related hooks */
  toolCallId?: string;
}

export interface HookBackgroundStartedEvent extends BaseTronEvent {
  type: 'hook.background_started';
  /** Names of background hooks being executed */
  hookNames: string[];
  /** Hook event type (PostToolUse, SessionEnd, etc.) */
  hookEvent: string;
  /** Unique ID to correlate started/completed events */
  executionId: string;
}

export interface HookBackgroundCompletedEvent extends BaseTronEvent {
  type: 'hook.background_completed';
  /** Names of background hooks that were executed */
  hookNames: string[];
  /** Hook event type (PostToolUse, SessionEnd, etc.) */
  hookEvent: string;
  /** Unique ID to correlate started/completed events */
  executionId: string;
  /** Result: 'continue' if all succeeded, 'error' if any failed */
  result: 'continue' | 'error';
  /** Execution duration in milliseconds */
  duration: number;
  /** Error message if result is 'error' */
  error?: string;
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
 * Compaction events
 */
export interface CompactionStartEvent extends BaseTronEvent {
  type: 'compaction_start';
  /** Why compaction was triggered */
  reason: 'pre_turn_guardrail' | 'threshold_exceeded' | 'manual';
  /** Token count before compaction */
  tokensBefore: number;
}

export interface CompactionCompleteEvent extends BaseTronEvent {
  type: 'compaction_complete';
  /** Whether compaction succeeded */
  success: boolean;
  /** Token count before compaction */
  tokensBefore: number;
  /** Token count after compaction */
  tokensAfter: number;
  /** Compression ratio achieved (0-1, lower is better) */
  compressionRatio: number;
  /** Why compaction was triggered */
  reason?: 'pre_turn_guardrail' | 'threshold_exceeded' | 'manual';
  /** Summary of compacted context (for display in UI) */
  summary?: string;
  /** Estimated total context tokens after compaction (system + tools + rules + compacted messages) */
  estimatedContextTokens?: number;
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
 * Retry event - emitted when a retryable error occurs (rate limit, network, etc.)
 */
export interface TronRetryEvent extends BaseTronEvent {
  type: 'api_retry';
  /** Current attempt number (1-based) */
  attempt: number;
  /** Maximum number of retries configured */
  maxRetries: number;
  /** Delay before next retry in milliseconds */
  delayMs: number;
  /** Error category that triggered the retry */
  errorCategory: string;
  /** Human-readable error message */
  errorMessage: string;
}

// =============================================================================
// Instagram Agent Events
// =============================================================================

/**
 * Instagram agent started event
 */
export interface InstagramAgentStartedEvent extends BaseTronEvent {
  type: 'instagram.agent.started';
  accountId: string;
  accountName: string;
}

/**
 * Instagram agent stopped event
 */
export interface InstagramAgentStoppedEvent extends BaseTronEvent {
  type: 'instagram.agent.stopped';
  accountId: string;
  reason?: string;
}

/**
 * Instagram agent error event
 */
export interface InstagramAgentErrorEvent extends BaseTronEvent {
  type: 'instagram.agent.error';
  accountId: string;
  error: string;
  errorType?: string;
}

/**
 * Instagram post generating event
 */
export interface InstagramPostGeneratingEvent extends BaseTronEvent {
  type: 'instagram.post.generating';
  accountId: string;
  productId: string;
  productName: string;
  stage: 'discovering' | 'generating_image' | 'generating_caption' | 'uploading';
}

/**
 * Instagram post published event
 */
export interface InstagramPostPublishedEvent extends BaseTronEvent {
  type: 'instagram.post.published';
  accountId: string;
  postId: string;
  permalink: string;
  productName: string;
  mediaType: string;
}

/**
 * Instagram post failed event
 */
export interface InstagramPostFailedEvent extends BaseTronEvent {
  type: 'instagram.post.failed';
  accountId: string;
  productId?: string;
  error: string;
  stage?: string;
}

/**
 * Instagram product discovered event
 */
export interface InstagramProductDiscoveredEvent extends BaseTronEvent {
  type: 'instagram.product.discovered';
  accountId: string;
  productId: string;
  productName: string;
  brand: string;
  commission: number;
  niche: string;
}

/**
 * Instagram analytics update event
 */
export interface InstagramAnalyticsUpdateEvent extends BaseTronEvent {
  type: 'instagram.analytics.update';
  accountId: string;
  totalPosts: number;
  totalEngagement: number;
  totalCommission: number;
}

/**
 * Union of all Instagram events
 */
export type InstagramEvent =
  | InstagramAgentStartedEvent
  | InstagramAgentStoppedEvent
  | InstagramAgentErrorEvent
  | InstagramPostGeneratingEvent
  | InstagramPostPublishedEvent
  | InstagramPostFailedEvent
  | InstagramProductDiscoveredEvent
  | InstagramAnalyticsUpdateEvent;

// =============================================================================
// Tron Thinking Events (agent-level with session context)
// Note: These are different from StreamEvent thinking types which are simpler
// =============================================================================

/**
 * Tron thinking started event (agent-level)
 */
export interface TronThinkingStartEvent extends BaseTronEvent {
  type: 'thinking_start';
}

/**
 * Tron thinking delta event (agent-level)
 */
export interface TronThinkingDeltaEvent extends BaseTronEvent {
  type: 'thinking_delta';
  delta: string;
}

/**
 * Tron thinking ended event (agent-level)
 */
export interface TronThinkingEndEvent extends BaseTronEvent {
  type: 'thinking_end';
  thinking: string;
}

/**
 * Union of all Tron agent events
 */
export type TronEvent =
  | AgentStartEvent
  | AgentEndEvent
  | AgentReadyEvent
  | AgentInterruptedEvent
  | TurnStartEvent
  | TurnEndEvent
  | TurnFailedEvent
  | ResponseCompleteEvent
  | MessageUpdateEvent
  | ToolUseBatchEvent
  | ToolExecutionStartEvent
  | ToolExecutionUpdateEvent
  | ToolExecutionEndEvent
  | ToolCallArgumentDeltaEvent
  | ToolCallGeneratingEvent
  | HookTriggeredEvent
  | HookCompletedEvent
  | HookBackgroundStartedEvent
  | HookBackgroundCompletedEvent
  | SessionSavedEvent
  | SessionLoadedEvent
  | ContextWarningEvent
  | CompactionStartEvent
  | CompactionCompleteEvent
  | TronErrorEvent
  | TronRetryEvent
  | InstagramEvent
  | TronThinkingStartEvent
  | TronThinkingDeltaEvent
  | TronThinkingEndEvent;

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
    'done', 'error', 'retry'
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

export function isInstagramEvent(event: TronEvent): event is InstagramEvent {
  return event.type.startsWith('instagram.');
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
