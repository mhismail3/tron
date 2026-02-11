/**
 * @fileoverview Tron message types
 *
 * These types define the structure of all messages in the Tron agent system.
 * They are designed to be:
 * - Fully serializable as JSON (for persistence and cross-session transfer)
 * - Provider-agnostic (can be converted to/from Anthropic, OpenAI, etc.)
 * - Type-safe with discriminated unions
 */

import type { Tool } from './tools.js';

// Import and re-export content types from content.ts (breaks circular dependency with tools.ts)
import type {
  TextContent,
  ImageContent,
  DocumentContent,
  ThinkingContent,
} from './content.js';

export type {
  TextContent,
  ImageContent,
  DocumentContent,
  ThinkingContent,
};

/**
 * Tool call content block
 */
export interface ToolCall {
  type: 'tool_use';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  /**
   * Thought signature for Gemini 3 models.
   * Required when replaying function calls back to Gemini.
   * If missing when converting for Gemini, a skip validator placeholder is used.
   */
  thoughtSignature?: string;
}

/**
 * Content types that can appear in user messages
 */
export type UserContent = TextContent | ImageContent | DocumentContent;

/**
 * Content types that can appear in assistant messages
 */
export type AssistantContent = TextContent | ThinkingContent | ToolCall;

/**
 * Content types that can appear in tool result messages
 */
export type ToolResultContent = TextContent | ImageContent;

// =============================================================================
// API-Format Types (for persistence and wire format)
// =============================================================================

/**
 * API-format tool_use content block.
 * Uses 'input' instead of 'arguments' to match Anthropic API wire format.
 * Used in persisted events and when sending messages to the API.
 */
export interface ApiToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input: Record<string, unknown>;
}

/**
 * API-format tool_result content block.
 * Used in persisted events and when sending tool results to the API.
 */
export interface ApiToolResultBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
  is_error?: boolean;
}

/**
 * Internal-format tool_result content block.
 * Used when tool results appear as content blocks (e.g., in normalized messages).
 * This is the counterpart to ApiToolResultBlock, using internal field names.
 */
export interface InternalToolResultBlock {
  type: 'tool_result';
  toolCallId: string;
  content: string;
  isError?: boolean;
}

// =============================================================================
// Conversion Utilities (internal ↔ API format)
// =============================================================================

/**
 * Convert internal ToolCall to API-format tool_use block.
 * This converts 'arguments' → 'input' for API compatibility.
 */
export function toApiToolUse(toolCall: ToolCall): ApiToolUseBlock {
  return {
    type: 'tool_use',
    id: toolCall.id,
    name: toolCall.name,
    input: toolCall.arguments,
  };
}

/**
 * Convert API-format tool_use block to internal ToolCall.
 * This converts 'input' → 'arguments' for internal use.
 */
export function fromApiToolUse(apiBlock: { id: string; name: string; input: Record<string, unknown> }): ToolCall {
  return {
    type: 'tool_use',
    id: apiBlock.id,
    name: apiBlock.name,
    arguments: apiBlock.input,
  };
}

/**
 * Normalize tool input/arguments - handles both API ('input') and internal ('arguments') naming.
 * Returns the arguments regardless of which field name was used.
 */
export function normalizeToolArguments(
  block: { input?: Record<string, unknown>; arguments?: Record<string, unknown> }
): Record<string, unknown> {
  return block.input ?? block.arguments ?? {};
}

/**
 * Normalize tool result ID - handles both API ('tool_use_id') and internal ('toolCallId') naming.
 */
export function normalizeToolResultId(
  block: { tool_use_id?: string; toolCallId?: string }
): string {
  return block.tool_use_id ?? block.toolCallId ?? '';
}

/**
 * Normalize error flag - handles both API ('is_error') and internal ('isError') naming.
 */
export function normalizeIsError(
  block: { is_error?: boolean; isError?: boolean }
): boolean {
  return block.is_error ?? block.isError ?? false;
}

// =============================================================================
// Token and Cost Tracking
// =============================================================================

/**
 * Provider types for token normalization.
 * Different providers report inputTokens differently:
 * - anthropic: inputTokens is NEW tokens only (excludes cache)
 * - openai/openai-codex/google: inputTokens is FULL context sent
 */
export type ProviderType = 'anthropic' | 'openai' | 'openai-codex' | 'google';

/**
 * Token usage information
 */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
  /** Provider type for normalization (different providers report tokens differently) */
  providerType?: ProviderType;
}

/**
 * Cost information
 */
export interface Cost {
  inputCost: number;
  outputCost: number;
  total: number;
  currency: string;
}

/**
 * Reasons why the model stopped generating
 */
export type StopReason = 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence' | 'refusal' | 'model_context_window_exceeded';

// =============================================================================
// Message Types
// =============================================================================

/**
 * Message from the user
 */
export interface UserMessage {
  role: 'user';
  content: string | UserContent[];
  timestamp?: number;
}

/**
 * Message from the assistant (LLM)
 */
export interface AssistantMessage {
  role: 'assistant';
  content: AssistantContent[];
  usage?: TokenUsage;
  cost?: Cost;
  stopReason?: StopReason;
  thinking?: string; // Convenience accessor for thinking content
}

/**
 * Tool execution result message
 */
export interface ToolResultMessage {
  role: 'toolResult';
  toolCallId: string;
  content: string | ToolResultContent[];
  isError?: boolean;
}

/**
 * Union type for all message types
 */
export type Message = UserMessage | AssistantMessage | ToolResultMessage;

// =============================================================================
// Context Types
// =============================================================================

/**
 * Full context for LLM requests
 */
export interface Context {
  systemPrompt?: string;
  messages: Message[];
  tools?: Tool[];
  /** Working directory for file operations (used by some providers for context) */
  workingDirectory?: string;
  /** Rules content from AGENTS.md / CLAUDE.md hierarchy (cacheable, static) */
  rulesContent?: string;
  /** Memory content (workspace lessons + cross-project recall) */
  memoryContent?: string;
  /** Skill context to inject as system-level instructions (ephemeral, changes per-skill) */
  skillContext?: string;
  /** Sub-agent results context to inform agent of completed sub-agent tasks */
  subagentResultsContext?: string;
  /** Task context showing current task list (ephemeral, updated per-turn) */
  taskContext?: string;
  /** Dynamic rules context from path-scoped .claude/rules/ files (changes as agent touches files) */
  dynamicRulesContext?: string;
}

// Tool and ToolInputSchema are re-exported from ./tools.js
// to maintain backward compatibility
export type { Tool, ToolParameterSchema as ToolInputSchema } from './tools.js';

// =============================================================================
// Type Guards
// =============================================================================

export function isUserMessage(msg: Message): msg is UserMessage {
  return msg.role === 'user';
}

export function isAssistantMessage(msg: Message): msg is AssistantMessage {
  return msg.role === 'assistant';
}

export function isToolResultMessage(msg: Message): msg is ToolResultMessage {
  return msg.role === 'toolResult';
}

export function isToolCall(content: AssistantContent): content is ToolCall {
  return content.type === 'tool_use';
}

export function isTextContent(
  content: UserContent | AssistantContent | ToolResultContent
): content is TextContent {
  return content.type === 'text';
}

export function isImageContent(
  content: UserContent | ToolResultContent
): content is ImageContent {
  return content.type === 'image';
}

export function isThinkingContent(content: AssistantContent): content is ThinkingContent {
  return content.type === 'thinking';
}

export function isApiToolResultBlock(block: unknown): block is ApiToolResultBlock {
  return (
    typeof block === 'object' &&
    block !== null &&
    (block as ApiToolResultBlock).type === 'tool_result' &&
    typeof (block as ApiToolResultBlock).tool_use_id === 'string'
  );
}

export function isInternalToolResultBlock(block: unknown): block is InternalToolResultBlock {
  return (
    typeof block === 'object' &&
    block !== null &&
    (block as InternalToolResultBlock).type === 'tool_result' &&
    typeof (block as InternalToolResultBlock).toolCallId === 'string'
  );
}

/**
 * Check if block is a tool_result in either API or internal format.
 */
export function isAnyToolResultBlock(block: unknown): block is ApiToolResultBlock | InternalToolResultBlock {
  return isApiToolResultBlock(block) || isInternalToolResultBlock(block);
}

export function isApiToolUseBlock(block: unknown): block is ApiToolUseBlock {
  return (
    typeof block === 'object' &&
    block !== null &&
    (block as ApiToolUseBlock).type === 'tool_use' &&
    typeof (block as ApiToolUseBlock).id === 'string' &&
    'input' in (block as ApiToolUseBlock)
  );
}

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Extract text from message content
 */
export function extractText(content: string | (TextContent | ImageContent)[]): string {
  if (typeof content === 'string') {
    return content;
  }
  return content
    .filter(isTextContent)
    .map(c => c.text)
    .join('\n');
}

/**
 * Extract tool calls from assistant message
 */
export function extractToolCalls(message: AssistantMessage): ToolCall[] {
  return message.content.filter(isToolCall);
}
