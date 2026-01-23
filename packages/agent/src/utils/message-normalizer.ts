/**
 * @fileoverview Message Normalization Utilities
 *
 * Provides functions to normalize message content between API format and internal format.
 * This ensures consistent handling throughout the system regardless of data source:
 *
 * API Format (from events, wire protocol):
 *   - tool_use_id, is_error (tool results)
 *   - input (tool calls)
 *
 * Internal Format (used in runtime):
 *   - toolCallId, isError (tool results)
 *   - arguments (tool calls)
 *
 * The normalizers always output internal format, and providers convert to their
 * respective API formats when making requests.
 */

import type {
  Message,
  ToolResultMessage,
  ToolCall,
  InternalToolResultBlock,
} from '../types/index.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Re-export InternalToolResultBlock as NormalizedToolResultBlock for clarity.
 * This is the canonical internal format for tool result content blocks.
 */
export type NormalizedToolResultBlock = InternalToolResultBlock & { isError: boolean };

/**
 * Normalized tool use block (internal format).
 * Uses 'arguments' instead of 'input'.
 */
export interface NormalizedToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

/**
 * Input type for tool result block that may be in either format.
 */
interface AnyToolResultBlock {
  type: 'tool_result';
  tool_use_id?: string;
  toolCallId?: string;
  content: string;
  is_error?: boolean;
  isError?: boolean;
}

/**
 * Input type for tool use block that may be in either format.
 */
interface AnyToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input?: Record<string, unknown>;
  arguments?: Record<string, unknown>;
}

// =============================================================================
// Type Guards
// =============================================================================

/**
 * Check if a content block is a tool_result (either format).
 */
export function isToolResultBlock(block: unknown): block is AnyToolResultBlock {
  if (!block || typeof block !== 'object') return false;
  const b = block as Record<string, unknown>;
  return (
    b.type === 'tool_result' &&
    (typeof b.tool_use_id === 'string' || typeof b.toolCallId === 'string')
  );
}

/**
 * Check if a content block is a tool_use (either format).
 */
export function isToolUseBlock(block: unknown): block is AnyToolUseBlock {
  if (!block || typeof block !== 'object') return false;
  const b = block as Record<string, unknown>;
  return (
    b.type === 'tool_use' &&
    typeof b.id === 'string' &&
    typeof b.name === 'string' &&
    (b.input !== undefined || b.arguments !== undefined)
  );
}

// =============================================================================
// Block Normalizers
// =============================================================================

/**
 * Normalize a tool_result block to internal format.
 * Handles both API format (tool_use_id, is_error) and internal format (toolCallId, isError).
 *
 * Internal format fields take precedence when both are present.
 */
export function normalizeToolResultBlock(block: AnyToolResultBlock): NormalizedToolResultBlock {
  return {
    type: 'tool_result',
    // Internal format (toolCallId) takes precedence over API format (tool_use_id)
    toolCallId: block.toolCallId ?? block.tool_use_id ?? '',
    content: block.content,
    // Internal format (isError) takes precedence over API format (is_error)
    isError: block.isError ?? block.is_error ?? false,
  };
}

/**
 * Normalize a tool_use block to internal format.
 * Handles both API format (input) and internal format (arguments).
 *
 * Internal format fields take precedence when both are present.
 */
export function normalizeToolUseBlock(block: AnyToolUseBlock): NormalizedToolUseBlock {
  return {
    type: 'tool_use',
    id: block.id,
    name: block.name,
    // Internal format (arguments) takes precedence over API format (input)
    arguments: block.arguments ?? block.input ?? {},
  };
}

// =============================================================================
// Content Array Normalizers
// =============================================================================

/**
 * Normalize an array of content blocks to internal format.
 * Processes tool_result and tool_use blocks, passes through other types unchanged.
 */
export function normalizeMessageContent(
  content: unknown[]
): unknown[] {
  return content.map((block) => {
    if (isToolResultBlock(block)) {
      return normalizeToolResultBlock(block);
    }
    if (isToolUseBlock(block)) {
      return normalizeToolUseBlock(block);
    }
    // Pass through other content types unchanged
    return block;
  });
}

// =============================================================================
// Message Normalizers
// =============================================================================

/**
 * Normalize a complete message to internal format.
 *
 * Key transformations:
 * 1. User messages with only tool_result content → ToolResultMessage(s)
 * 2. Assistant messages with tool_use blocks → normalized arguments
 * 3. Other messages → passed through unchanged
 *
 * @param message - Message in any format
 * @returns Normalized message or array of messages (when multiple tool results)
 */
export function normalizeMessage(message: Message): Message | Message[] {
  // Handle toolResult messages - already in internal format
  if (message.role === 'toolResult') {
    return message;
  }

  // Handle user messages
  if (message.role === 'user') {
    // String content - pass through unchanged
    if (typeof message.content === 'string') {
      return message;
    }

    // Check if this is a synthetic user message containing only tool_result blocks
    // (as created by message-reconstructor)
    const contentArray = message.content as unknown as Array<{ type: string; [key: string]: unknown }>;
    const hasOnlyToolResults =
      contentArray.length > 0 &&
      contentArray.every((c) => c.type === 'tool_result');

    if (hasOnlyToolResults) {
      // Convert to proper ToolResultMessage(s)
      if (contentArray.length === 1) {
        const normalized = normalizeToolResultBlock(contentArray[0] as unknown as AnyToolResultBlock);
        return {
          role: 'toolResult',
          toolCallId: normalized.toolCallId,
          content: normalized.content,
          isError: normalized.isError,
        } as ToolResultMessage;
      }

      // Multiple tool results - return array of ToolResultMessages
      return contentArray.map((c) => {
        const normalized = normalizeToolResultBlock(c as unknown as AnyToolResultBlock);
        return {
          role: 'toolResult',
          toolCallId: normalized.toolCallId,
          content: normalized.content,
          isError: normalized.isError,
        } as ToolResultMessage;
      });
    }

    // Regular user message with text/image content - pass through unchanged
    return message;
  }

  // Handle assistant messages - normalize tool_use blocks
  if (message.role === 'assistant') {
    const normalizedContent = normalizeMessageContent(message.content as unknown[]);
    return {
      ...message,
      content: normalizedContent as unknown as ToolCall[],
    };
  }

  // Unknown role - pass through unchanged
  return message;
}

/**
 * Normalize an array of messages to internal format.
 * Flattens arrays when normalizeMessage returns multiple messages.
 */
export function normalizeMessages(messages: Message[]): Message[] {
  const result: Message[] = [];

  for (const message of messages) {
    const normalized = normalizeMessage(message);
    if (Array.isArray(normalized)) {
      result.push(...normalized);
    } else {
      result.push(normalized);
    }
  }

  return result;
}
