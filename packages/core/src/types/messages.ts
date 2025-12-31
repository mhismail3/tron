/**
 * @fileoverview Tron message types
 *
 * These types define the structure of all messages in the Tron agent system.
 * They are designed to be:
 * - Fully serializable as JSON (for persistence and cross-session transfer)
 * - Provider-agnostic (can be converted to/from Anthropic, OpenAI, etc.)
 * - Type-safe with discriminated unions
 */

// =============================================================================
// Content Types
// =============================================================================

/**
 * Text content block
 */
export interface TextContent {
  type: 'text';
  text: string;
}

/**
 * Image content block (base64 encoded)
 */
export interface ImageContent {
  type: 'image';
  data: string; // base64 encoded
  mimeType: string;
}

/**
 * Thinking content block (Claude extended thinking)
 */
export interface ThinkingContent {
  type: 'thinking';
  thinking: string;
  signature?: string; // For verification
}

/**
 * Tool call content block
 */
export interface ToolCall {
  type: 'tool_use';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

/**
 * Content types that can appear in user messages
 */
export type UserContent = TextContent | ImageContent;

/**
 * Content types that can appear in assistant messages
 */
export type AssistantContent = TextContent | ThinkingContent | ToolCall;

/**
 * Content types that can appear in tool result messages
 */
export type ToolResultContent = TextContent | ImageContent;

// =============================================================================
// Token and Cost Tracking
// =============================================================================

/**
 * Token usage information
 */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
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
export type StopReason = 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence';

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
}

/**
 * Basic tool definition (for context)
 */
export interface Tool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

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
