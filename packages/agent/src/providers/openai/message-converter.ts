/**
 * @fileoverview OpenAI Message Converter
 *
 * Converts between Tron message format and OpenAI Responses API format.
 * Handles tool call ID remapping for cross-provider compatibility.
 */

import type { Context, TextContent, ToolCall, ImageContent } from '../../types/index.js';
import { buildToolCallIdMapping, remapToolCallId } from '../base/index.js';
import type { ResponsesInputItem, ResponsesTool, MessageContent, OpenAIInputImage } from './types.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('openai:converter');

/**
 * Convert an image content block to OpenAI input_image format
 */
function convertImageToOpenAI(image: ImageContent): OpenAIInputImage {
  return {
    type: 'input_image',
    image_url: `data:${image.mimeType};base64,${image.data}`,
    detail: 'auto',
  };
}

/**
 * Generate a tool clarification message to prepend to conversation.
 * Since we can't modify the system prompt, we add this as a "developer" context message.
 *
 * This includes:
 * 1. Tron identity and role
 * 2. Available tools and their descriptions
 * 3. Bash capabilities (since Codex's default instructions mention shell which we don't use)
 */
export function generateToolClarificationMessage(
  tools: Array<{ name: string; description: string; parameters?: unknown }>,
  workingDirectory?: string
): string {
  const toolDescriptions = tools.map(t => {
    const params = t.parameters as { properties?: Record<string, { description?: string }>; required?: string[] } | undefined;
    const requiredParams = params?.required?.join(', ') || 'none';
    return `- **${t.name}**: ${t.description} (required params: ${requiredParams})`;
  }).join('\n');

  const cwdLine = workingDirectory ? `\nCurrent working directory: ${workingDirectory}` : '';

  return `[TRON CONTEXT]
You are Tron, an AI coding assistant with full access to the user's file system.
${cwdLine}

## Available Tools
The tools mentioned in the system instructions (shell, apply_patch, etc.) are NOT available. Use ONLY these tools:

${toolDescriptions}

## Bash Tool Capabilities
The Bash tool runs commands on the user's local machine with FULL capabilities:
- **Network access**: Use curl, wget, or other tools to fetch URLs, APIs, websites
- **File system**: Full read/write access to files and directories
- **Git operations**: Clone, commit, push, pull, etc.
- **Package managers**: npm, pip, brew, apt, etc.
- **Any installed CLI tools**: rg, jq, python, node, etc.

When asked to visit a website or fetch data from the internet, USE the Bash tool with curl. Example: \`curl -s https://example.com\`

## Important Rules
1. You MUST provide ALL required parameters when calling tools - never call with empty arguments
2. For file paths, provide the complete path (e.g., "src/index.ts" or "/absolute/path/file.txt")
3. Confidently interpret and explain results from tool calls - you have full context of what was returned
4. Be helpful, accurate, and efficient when working with code
5. Read existing files to understand context before making changes
6. Make targeted, minimal edits rather than rewriting entire files`;
}

/**
 * Convert Tron context to Responses API input format
 *
 * Note: Tool call IDs from other providers (e.g., Anthropic's `toolu_` prefix)
 * are remapped to OpenAI-compatible format to support mid-session provider switching.
 */
export function convertToResponsesInput(context: Context): ResponsesInputItem[] {
  const input: ResponsesInputItem[] = [];

  // Build a mapping of original tool call IDs to normalized IDs.
  // This is necessary when switching providers mid-session, as tool call IDs
  // from other providers (e.g., Anthropic's `toolu_01...`) are not recognized.
  const allToolCalls: ToolCall[] = [];
  for (const msg of context.messages) {
    if (msg.role === 'assistant') {
      const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
      allToolCalls.push(...toolUses);
    }
  }
  const idMapping = buildToolCallIdMapping(allToolCalls, 'openai');

  // Convert messages with remapped IDs
  for (const msg of context.messages) {
    if (msg.role === 'user') {
      if (typeof msg.content === 'string') {
        input.push({
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text: msg.content }],
        });
      } else {
        const contentParts: MessageContent[] = [];

        for (const c of msg.content) {
          if (c.type === 'text') {
            contentParts.push({ type: 'input_text', text: c.text });
          } else if (c.type === 'image') {
            contentParts.push(convertImageToOpenAI(c));
          } else if (c.type === 'document') {
            logger.warn('Document content not fully supported by OpenAI, adding as reference', {
              mimeType: c.mimeType,
              fileName: c.fileName,
            });
            contentParts.push({
              type: 'input_text',
              text: `[Document: ${c.fileName || 'unnamed'} (${c.mimeType})]`,
            });
          }
        }

        if (contentParts.length > 0) {
          input.push({
            type: 'message',
            role: 'user',
            content: contentParts,
          });
        }
      }
    } else if (msg.role === 'assistant') {
      // Handle assistant messages with text
      const textParts = msg.content
        .filter(c => c.type === 'text')
        .map(c => (c as TextContent).text);

      if (textParts.length > 0) {
        input.push({
          type: 'message',
          role: 'assistant',
          content: textParts.map(text => ({ type: 'output_text', text })),
        });
      }

      // Handle tool calls from assistant
      const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
      for (const tc of toolUses) {
        input.push({
          type: 'function_call',
          call_id: remapToolCallId(tc.id, idMapping),
          name: tc.name,
          // Ensure arguments is always a valid JSON string (required by Responses API)
          arguments: JSON.stringify(tc.arguments ?? {}),
        });
      }
    } else if (msg.role === 'toolResult') {
      const output = typeof msg.content === 'string'
        ? msg.content
        : msg.content
            .filter(c => c.type === 'text')
            .map(c => (c as TextContent).text)
            .join('\n');

      // Truncate long outputs (Codex has 16k limit per output)
      const truncatedOutput = output.length > 16000
        ? output.slice(0, 16000) + '\n... [truncated]'
        : output;

      input.push({
        type: 'function_call_output',
        call_id: remapToolCallId(msg.toolCallId, idMapping),
        output: truncatedOutput,
      });
    }
  }

  return input;
}

/**
 * Convert Tron tools to Responses API format
 */
export function convertTools(tools: NonNullable<Context['tools']>): ResponsesTool[] {
  return tools.map(tool => ({
    type: 'function' as const,
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters as Record<string, unknown>,
  }));
}
