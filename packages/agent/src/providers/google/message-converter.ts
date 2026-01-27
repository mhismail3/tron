/**
 * @fileoverview Google Gemini Message Conversion
 *
 * Handles conversion between Tron message format and Gemini API format.
 * Supports:
 * - User messages (text)
 * - Assistant messages (text, tool calls with thought signatures)
 * - Tool result messages
 * - Tool call ID remapping for cross-provider compatibility
 */

import type {
  Context,
  ToolCall,
  TextContent,
  AssistantMessage,
  UserMessage,
  ToolResultMessage,
} from '../../types/index.js';
import { buildToolCallIdMapping, remapToolCallId } from '../base/index.js';
import type { GeminiContent, GeminiPart, GeminiTool } from './types.js';

// =============================================================================
// Message Conversion
// =============================================================================

/**
 * Convert Tron messages to Gemini format
 *
 * Note: Tool call IDs from other providers are remapped to ensure consistency
 * when switching providers mid-session.
 */
export function convertMessages(context: Context): GeminiContent[] {
  const contents: GeminiContent[] = [];

  // Build a mapping of original tool call IDs to normalized IDs.
  // This is necessary when switching providers mid-session.
  const allToolCalls: ToolCall[] = [];
  for (const msg of context.messages) {
    if (msg.role === 'assistant') {
      const assistantMsg = msg as AssistantMessage;
      const toolUses = assistantMsg.content.filter((c): c is ToolCall => c.type === 'tool_use');
      allToolCalls.push(...toolUses);
    }
  }
  const idMapping = buildToolCallIdMapping(allToolCalls, 'openai');

  for (const msg of context.messages) {
    if (msg.role === 'user') {
      const userMsg = msg as UserMessage;
      const parts: GeminiPart[] = [];

      if (typeof userMsg.content === 'string') {
        parts.push({ text: userMsg.content });
      } else {
        for (const c of userMsg.content) {
          if (c.type === 'text') {
            parts.push({ text: c.text });
          }
          // Note: Image handling would go here for multimodal
        }
      }

      if (parts.length > 0) {
        contents.push({ role: 'user', parts });
      }
    } else if (msg.role === 'assistant') {
      const assistantMsg = msg as AssistantMessage;
      const parts: GeminiPart[] = [];

      for (const c of assistantMsg.content) {
        if (c.type === 'text') {
          parts.push({ text: c.text });
        } else if (c.type === 'tool_use') {
          // For Gemini 3, function calls require thoughtSignature at the part level.
          // Use the stored signature if available (from previous Gemini responses),
          // otherwise use the skip validator for historical function calls from other providers.
          const thoughtSig = c.thoughtSignature || 'skip_thought_signature_validator';
          parts.push({
            functionCall: {
              name: c.name,
              args: c.arguments,
            },
            thoughtSignature: thoughtSig,
          } as GeminiPart);
        }
      }

      contents.push({ role: 'model', parts });
    } else if (msg.role === 'toolResult') {
      const toolResultMsg = msg as ToolResultMessage;
      const content = typeof toolResultMsg.content === 'string'
        ? toolResultMsg.content
        : toolResultMsg.content
            .filter(c => c.type === 'text')
            .map(c => (c as TextContent).text)
            .join('\n');

      // Gemini expects function responses as model turns followed by user turns
      // This is a simplification - actual implementation may need adjustment
      contents.push({
        role: 'user',
        parts: [{
          functionResponse: {
            name: 'tool_result',
            response: {
              result: content,
              tool_call_id: remapToolCallId(toolResultMsg.toolCallId, idMapping),
            },
          },
        }],
      });
    }
  }

  return contents;
}

// =============================================================================
// Tool Conversion
// =============================================================================

/**
 * Convert Tron tools to Gemini format
 */
export function convertTools(tools: NonNullable<Context['tools']>): GeminiTool[] {
  return [{
    functionDeclarations: tools.map(tool => ({
      name: tool.name,
      description: tool.description,
      parameters: sanitizeSchemaForGemini(tool.parameters as Record<string, unknown>),
    })),
  }];
}

/**
 * Sanitize JSON Schema for Gemini API compatibility.
 * Gemini doesn't support certain JSON Schema properties like additionalProperties.
 */
export function sanitizeSchemaForGemini(schema: Record<string, unknown>): Record<string, unknown> {
  if (!schema || typeof schema !== 'object') {
    return schema;
  }

  const result: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(schema)) {
    // Skip unsupported properties
    if (key === 'additionalProperties' || key === '$schema') {
      continue;
    }

    // Recursively sanitize nested objects
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      result[key] = sanitizeSchemaForGemini(value as Record<string, unknown>);
    } else if (Array.isArray(value)) {
      // Sanitize arrays (e.g., items in allOf, anyOf, oneOf)
      result[key] = value.map(item =>
        item && typeof item === 'object'
          ? sanitizeSchemaForGemini(item as Record<string, unknown>)
          : item
      );
    } else {
      result[key] = value;
    }
  }

  return result;
}
