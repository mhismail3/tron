/**
 * @fileoverview Anthropic Message Conversion
 *
 * Handles conversion between Tron message format and Anthropic API format.
 * Supports:
 * - User messages (text, images, documents)
 * - Assistant messages (text, thinking, tool_use)
 * - Tool result messages
 * - Tool call ID remapping for cross-provider compatibility
 */

import type Anthropic from '@anthropic-ai/sdk';
import type {
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  Context,
  ToolCall,
  TextContent,
  ThinkingContent,
  AssistantContent,
  ToolResultContent,
} from '../../types/index.js';
import { createLogger } from '../../logging/index.js';
import { buildToolCallIdMapping, remapToolCallId } from '../base/index.js';

const logger = createLogger('anthropic:converter');

// =============================================================================
// Message Conversion
// =============================================================================

/**
 * Convert Tron messages to Anthropic format
 *
 * Note: Tool call IDs from other providers (e.g., OpenAI's `call_` prefix)
 * are remapped to Anthropic-compatible format to support mid-session provider switching.
 */
export function convertMessages(
  messages: Message[]
): Anthropic.Messages.MessageParam[] {
  // Build a mapping of original tool call IDs to normalized IDs.
  // This is necessary when switching providers mid-session, as tool call IDs
  // from other providers (e.g., OpenAI's `call_...`) may not be recognized.
  const allToolCalls: ToolCall[] = [];
  for (const msg of messages) {
    if (msg.role === 'assistant') {
      const assistantMsg = msg as AssistantMessage;
      const toolUses = assistantMsg.content.filter((c): c is ToolCall => c.type === 'tool_use');
      allToolCalls.push(...toolUses);
    }
  }
  const idMapping = buildToolCallIdMapping(allToolCalls, 'anthropic');

  return messages
    .filter((msg): msg is Message => msg.role !== 'toolResult' || !!(msg as ToolResultMessage).toolCallId)
    .map((msg) => {
      if (msg.role === 'user') {
        return convertUserMessage(msg as UserMessage, idMapping);
      }

      if (msg.role === 'assistant') {
        return convertAssistantMessage(msg as AssistantMessage, idMapping);
      }

      if (msg.role === 'toolResult') {
        return convertToolResultMessage(msg as ToolResultMessage, idMapping);
      }

      return { role: 'user' as const, content: '' };
    });
}

/**
 * Convert user message to Anthropic format
 */
function convertUserMessage(
  msg: UserMessage,
  idMapping: Map<string, string>
): Anthropic.Messages.MessageParam {
  const content = typeof msg.content === 'string'
    ? msg.content
    : msg.content.map((c) => {
        if (c.type === 'text') return { type: 'text' as const, text: c.text };
        if (c.type === 'image') {
          return {
            type: 'image' as const,
            source: {
              type: 'base64' as const,
              media_type: c.mimeType as 'image/jpeg' | 'image/png' | 'image/gif' | 'image/webp',
              data: c.data,
            },
          };
        }
        if (c.type === 'document') {
          return {
            type: 'document' as const,
            source: {
              type: 'base64' as const,
              media_type: c.mimeType as 'application/pdf',
              data: c.data,
            },
          };
        }
        // Handle tool_result content blocks stored in message.user events
        // (created at turn end for proper sequencing after message.assistant)
        const maybeToolResult = c as { type: string; tool_use_id?: string; content?: string; is_error?: boolean };
        if (maybeToolResult.type === 'tool_result') {
          return {
            type: 'tool_result' as const,
            tool_use_id: remapToolCallId(maybeToolResult.tool_use_id!, idMapping),
            content: maybeToolResult.content,
            is_error: maybeToolResult.is_error,
          };
        }
        return { type: 'text' as const, text: '' };
      });
  return { role: 'user' as const, content };
}

/**
 * Convert assistant message to Anthropic format
 */
function convertAssistantMessage(
  msg: AssistantMessage,
  idMapping: Map<string, string>
): Anthropic.Messages.MessageParam {
  // Map content blocks - thinking blocks MUST be preserved
  // When thinking is enabled, the API requires assistant messages to include
  // their thinking blocks. Without them, we get:
  // "Expected `thinking` or `redacted_thinking`, but found `tool_use`"
  const content = msg.content
    .map((c: AssistantContent) => {
      if (c.type === 'text') return { type: 'text' as const, text: c.text };
      if (c.type === 'tool_use') {
        // Handle both 'arguments' (in-memory ToolCall type) and 'input' (persisted event format)
        const input = c.arguments ?? (c as any).input ?? {};
        return {
          type: 'tool_use' as const,
          id: remapToolCallId(c.id, idMapping),
          name: c.name,
          input,
        };
      }
      // Thinking blocks - CRITICAL: Only include if they have signatures
      // Extended thinking models (Opus 4.5) provide signatures and require them in conversation history
      // Non-extended thinking models (Haiku, Sonnet) don't provide signatures - these thinking blocks
      // are display-only and should NOT be sent back to the API
      if (c.type === 'thinking') {
        if (!c.signature) {
          // No signature = display-only thinking block, don't send back to API
          return null;
        }
        return {
          type: 'thinking' as const,
          thinking: c.thinking,
          signature: c.signature,
        };
      }
      // Exhaustive check - all content types should be handled above
      // This should never be reached, but log if it somehow is
      const exhaustiveCheck: never = c;
      logger.warn('Unknown assistant content type, skipping', { type: (exhaustiveCheck as AssistantContent).type });
      return null;
    })
    .filter((c): c is NonNullable<typeof c> => c !== null);

  // Warn if assistant message ends up with empty content (likely a bug)
  if (content.length === 0) {
    logger.error('Assistant message has empty content after conversion', {
      originalContentCount: msg.content.length,
      originalTypes: msg.content.map((c: AssistantContent) => c.type),
    });
  }

  return { role: 'assistant' as const, content };
}

/**
 * Convert tool result message to Anthropic format
 */
function convertToolResultMessage(
  msg: ToolResultMessage,
  idMapping: Map<string, string>
): Anthropic.Messages.MessageParam {
  const content = typeof msg.content === 'string'
    ? msg.content
    : msg.content.map((c: ToolResultContent) => {
        if (c.type === 'text') return { type: 'text' as const, text: c.text };
        if (c.type === 'image') {
          return {
            type: 'image' as const,
            source: {
              type: 'base64' as const,
              media_type: c.mimeType as 'image/jpeg' | 'image/png' | 'image/gif' | 'image/webp',
              data: c.data,
            },
          };
        }
        return { type: 'text' as const, text: '' };
      });
  return {
    role: 'user' as const,
    content: [{
      type: 'tool_result' as const,
      tool_use_id: remapToolCallId(msg.toolCallId, idMapping),
      content,
      is_error: msg.isError,
    }],
  };
}

// =============================================================================
// Tool Conversion
// =============================================================================

/**
 * Convert Tron tools to Anthropic format
 */
export function convertTools(
  tools: NonNullable<Context['tools']>
): Anthropic.Messages.Tool[] {
  return tools.map((tool) => ({
    name: tool.name,
    description: tool.description,
    input_schema: tool.parameters as Anthropic.Messages.Tool['input_schema'],
  }));
}

// =============================================================================
// Response Conversion
// =============================================================================

/**
 * Convert Anthropic response to Tron format
 */
export function convertResponse(
  response: Anthropic.Messages.Message
): {
  role: 'assistant';
  content: (TextContent | ThinkingContent | ToolCall)[];
  usage: {
    inputTokens: number;
    outputTokens: number;
    cacheCreationTokens?: number;
    cacheReadTokens?: number;
    providerType: 'anthropic';
  };
  stopReason?: string;
} {
  const content: (TextContent | ThinkingContent | ToolCall)[] = [];

  // Handle case where response or content might be malformed
  if (!response) {
    return {
      role: 'assistant',
      content: [],
      usage: { inputTokens: 0, outputTokens: 0, providerType: 'anthropic' },
    };
  }

  // Handle case where content might not be iterable
  const blocks = Array.isArray(response.content) ? response.content : [];
  for (const block of blocks) {
    // Cast to unknown first to handle thinking blocks which aren't in the base SDK types
    const blockType = (block as { type: string }).type;
    if (blockType === 'text') {
      content.push({ type: 'text', text: (block as { text: string }).text });
    } else if (blockType === 'thinking') {
      // Extract thinking content from extended thinking response
      // IMPORTANT: Only include if signature is present (extended thinking models only)
      const thinkingBlock = block as unknown as { thinking: string; signature?: string };
      if (thinkingBlock.signature) {
        content.push({
          type: 'thinking',
          thinking: thinkingBlock.thinking,
          signature: thinkingBlock.signature,
        });
      }
      // If no signature, this is display-only thinking from non-extended model - skip it
    } else if (blockType === 'tool_use') {
      const toolBlock = block as { id: string; name: string; input: unknown };
      content.push({
        type: 'tool_use',
        id: toolBlock.id,
        name: toolBlock.name,
        arguments: toolBlock.input as Record<string, unknown>,
      });
    }
  }

  // Extract cache tokens from usage (Anthropic's extended usage object)
  const usageWithCache = response.usage as {
    input_tokens?: number;
    output_tokens?: number;
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
  } | undefined;

  return {
    role: 'assistant',
    content,
    usage: {
      inputTokens: usageWithCache?.input_tokens ?? 0,
      outputTokens: usageWithCache?.output_tokens ?? 0,
      cacheCreationTokens: usageWithCache?.cache_creation_input_tokens,
      cacheReadTokens: usageWithCache?.cache_read_input_tokens,
      providerType: 'anthropic' as const,
    },
    stopReason: response.stop_reason ?? undefined,
  };
}
