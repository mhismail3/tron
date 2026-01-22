/**
 * @fileoverview Content Block Normalization Utilities
 *
 * Provides utilities for normalizing and sanitizing content blocks for storage.
 * Handles tool_use, tool_result, text, and thinking block types with appropriate
 * truncation for large content.
 */
import { createLogger } from '@tron/core';

const logger = createLogger('content-normalizer');

// =============================================================================
// Constants
// =============================================================================

/**
 * Maximum size for tool result content before truncation (10KB)
 */
export const MAX_TOOL_RESULT_SIZE = 10 * 1024;

/**
 * Maximum size for tool input arguments before truncation (5KB)
 */
export const MAX_TOOL_INPUT_SIZE = 5 * 1024;

// =============================================================================
// Utilities
// =============================================================================

/**
 * Truncate a string to the specified max length, adding a truncation notice
 */
export function truncateString(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  const truncated = str.slice(0, maxLength);
  const remaining = str.length - maxLength;
  return `${truncated}\n\n... [truncated ${remaining} characters]`;
}

/**
 * Normalize and sanitize a content block for storage.
 * Ensures all required fields are present and applies truncation for large content.
 */
export function normalizeContentBlock(block: unknown): Record<string, unknown> | null {
  if (typeof block !== 'object' || block === null) return null;

  const b = block as Record<string, unknown>;
  const type = b.type;

  if (typeof type !== 'string') return null;

  switch (type) {
    case 'text':
      return {
        type: 'text',
        text: typeof b.text === 'string' ? b.text : String(b.text ?? ''),
      };

    case 'tool_use': {
      const toolName = typeof b.name === 'string' ? b.name : String(b.name ?? 'unknown');

      // IMPORTANT: The Anthropic API uses 'input', but our internal ToolCall type uses 'arguments'
      // We need to check for BOTH to handle both sources correctly
      const rawInput = b.input ?? b.arguments;
      const hasInputKey = 'input' in b;
      const hasArgumentsKey = 'arguments' in b;

      logger.debug('Normalizing tool_use block', {
        toolName,
        blockKeys: Object.keys(b),
        hasInputKey,
        hasArgumentsKey,
        inputType: typeof rawInput,
        inputIsObject: rawInput !== null && typeof rawInput === 'object',
        inputKeys: rawInput && typeof rawInput === 'object' ? Object.keys(rawInput as object) : [],
        inputPreview: rawInput ? JSON.stringify(rawInput).slice(0, 200) : 'undefined/null',
      });

      // Preserve the full input object with potential truncation for very large inputs
      let input = rawInput;
      if (input && typeof input === 'object') {
        // Deep clone to avoid mutating original and ensure it serializes correctly
        try {
          const inputStr = JSON.stringify(input);
          // Parse it back to ensure clean serialization (removes any class instances/prototypes)
          input = JSON.parse(inputStr);
          if (inputStr.length > MAX_TOOL_INPUT_SIZE) {
            // For very large inputs, store a truncated version
            input = {
              _truncated: true,
              _originalSize: inputStr.length,
              _preview: inputStr.slice(0, MAX_TOOL_INPUT_SIZE),
            };
          }
        } catch (e) {
          // If JSON.stringify fails, try to extract what we can
          logger.warn('Failed to serialize tool input', { toolName, error: String(e) });
          input = { _serializationError: true };
        }
      } else if (input === undefined || input === null) {
        // Explicitly log when input is missing
        logger.warn('Tool use block has no input', { toolName, hasInputKey, hasArgumentsKey });
        input = {};
      }

      const result = {
        type: 'tool_use' as const,
        id: typeof b.id === 'string' ? b.id : String(b.id ?? ''),
        name: toolName,
        input: input,
      };

      logger.debug('Normalized tool_use result', {
        toolName,
        inputKeys: Object.keys(result.input as object),
        hasContent: Object.keys(result.input as object).length > 0,
      });

      return result;
    }

    case 'tool_result': {
      // IMPORTANT: Anthropic API uses 'tool_use_id', but our internal ToolResultMessage uses 'toolCallId'
      // We need to check for BOTH to handle both sources correctly
      const toolUseId = typeof b.tool_use_id === 'string' ? b.tool_use_id :
                        typeof b.toolCallId === 'string' ? b.toolCallId :
                        String(b.tool_use_id ?? b.toolCallId ?? '');
      const blockKeys = Object.keys(b);
      const rawContent = b.content;
      const isError = b.is_error === true || b.isError === true;

      logger.debug('Normalizing tool_result block', {
        toolUseId: toolUseId.slice(0, 20) + '...',
        blockKeys,
        contentType: typeof rawContent,
        contentIsArray: Array.isArray(rawContent),
        contentLength: typeof rawContent === 'string' ? rawContent.length :
                       Array.isArray(rawContent) ? rawContent.length : 0,
        contentPreview: typeof rawContent === 'string' ? rawContent.slice(0, 100) :
                       Array.isArray(rawContent) ? JSON.stringify(rawContent).slice(0, 100) : 'N/A',
      });

      // Handle content which can be a string or array
      let content = rawContent;

      if (typeof content === 'string') {
        // Truncate very large string results
        if (content.length > MAX_TOOL_RESULT_SIZE) {
          content = truncateString(content, MAX_TOOL_RESULT_SIZE);
        }
      } else if (Array.isArray(content)) {
        // Content is an array of content parts (e.g., text + images)
        // Extract text and truncate if needed
        const textParts = content
          .filter((p): p is { type: string; text: string } =>
            typeof p === 'object' && p !== null && p.type === 'text' && typeof p.text === 'string'
          )
          .map(p => p.text)
          .join('\n');

        content = textParts.length > MAX_TOOL_RESULT_SIZE
          ? truncateString(textParts, MAX_TOOL_RESULT_SIZE)
          : textParts || JSON.stringify(rawContent);
      } else if (content !== undefined && content !== null) {
        content = String(content);
      } else {
        content = '';
      }

      const result = {
        type: 'tool_result' as const,
        tool_use_id: toolUseId,
        content,
        is_error: isError,
      };

      logger.debug('Normalized tool_result result', {
        toolUseId: toolUseId.slice(0, 20) + '...',
        contentLength: typeof result.content === 'string' ? result.content.length : 0,
        isError: result.is_error,
      });

      return result;
    }

    case 'thinking':
      // IMPORTANT: Must preserve signature - API requires it when sending thinking back
      return {
        type: 'thinking',
        thinking: typeof b.thinking === 'string' ? b.thinking : String(b.thinking ?? ''),
        signature: typeof b.signature === 'string' ? b.signature : undefined,
      };

    default:
      // Unknown type - preserve as-is
      return { ...b };
  }
}

/**
 * Normalize an array of content blocks for storage
 */
export function normalizeContentBlocks(content: unknown): Record<string, unknown>[] {
  if (!Array.isArray(content)) {
    // Single string content
    if (typeof content === 'string') {
      return [{ type: 'text', text: content }];
    }
    return [];
  }

  return content
    .map(normalizeContentBlock)
    .filter((b): b is Record<string, unknown> => b !== null);
}
