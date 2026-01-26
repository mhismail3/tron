/**
 * @fileoverview Tool Call ID Remapping Utilities
 *
 * When switching providers mid-session, tool call IDs from one provider
 * may not be recognized by another. This module provides utilities to
 * remap IDs to the target provider's format.
 *
 * ID formats:
 * - Anthropic: toolu_01abc123... (prefix: toolu_)
 * - OpenAI: call_abc123... (prefix: call_)
 * - Google/Gemini: Uses call_* format internally
 *
 * The remapping is transparent to the rest of the system - original IDs
 * are preserved in events/persistence, remapping happens only at the
 * API boundary when sending messages to providers.
 */

import type { ToolCall } from '../../types/messages.js';

/**
 * ID format for different providers
 */
export type IdFormat = 'anthropic' | 'openai';

/**
 * Check if an ID is in Anthropic format (toolu_* prefix)
 */
export function isAnthropicId(id: string): boolean {
  return id.startsWith('toolu_');
}

/**
 * Check if an ID is in OpenAI format (call_* prefix)
 */
export function isOpenAIId(id: string): boolean {
  return id.startsWith('call_');
}

/**
 * Build a mapping of tool call IDs that need remapping for a target format.
 *
 * This scans the tool calls and creates a mapping for any IDs that don't
 * match the target format. IDs already in the correct format are not mapped.
 *
 * @param toolCalls - Array of tool calls to analyze
 * @param targetFormat - Target ID format ('anthropic' or 'openai')
 * @returns Map of original ID → remapped ID (only contains IDs that need remapping)
 *
 * @example
 * ```typescript
 * // When switching from OpenAI to Anthropic
 * const toolCalls = [{ id: 'call_abc', name: 'test', ... }];
 * const mapping = buildToolCallIdMapping(toolCalls, 'anthropic');
 * // mapping.get('call_abc') => 'toolu_remap_0'
 * ```
 */
export function buildToolCallIdMapping(
  toolCalls: ToolCall[],
  targetFormat: IdFormat
): Map<string, string> {
  const mapping = new Map<string, string>();
  let counter = 0;

  const prefix = targetFormat === 'anthropic' ? 'toolu_remap_' : 'call_remap_';
  const isCorrectFormat = targetFormat === 'anthropic' ? isAnthropicId : isOpenAIId;

  for (const tc of toolCalls) {
    // Only remap IDs that aren't already in the target format
    if (!mapping.has(tc.id) && !isCorrectFormat(tc.id)) {
      mapping.set(tc.id, `${prefix}${counter++}`);
    }
  }

  return mapping;
}

/**
 * Remap a tool call ID using a mapping, or return the original if not mapped.
 *
 * @param id - Original tool call ID
 * @param mapping - Mapping from buildToolCallIdMapping()
 * @returns Remapped ID if in mapping, otherwise original ID
 */
export function remapToolCallId(
  id: string,
  mapping: Map<string, string>
): string {
  return mapping.get(id) ?? id;
}

/**
 * Extract tool calls from assistant messages for ID mapping.
 *
 * Helper to scan messages and collect all tool calls that need mapping.
 * Filters for assistant messages and extracts tool_use content blocks.
 *
 * @param messages - Array of messages to scan
 * @returns Array of tool calls found in assistant messages
 */
export function collectToolCallsFromMessages(
  messages: Array<{ role: string; content: Array<{ type: string; id?: string; name?: string }> }>
): ToolCall[] {
  const toolCalls: ToolCall[] = [];

  for (const msg of messages) {
    if (msg.role === 'assistant') {
      for (const block of msg.content) {
        if (block.type === 'tool_use' && block.id && block.name) {
          toolCalls.push({
            type: 'tool_use',
            id: block.id,
            name: block.name,
            arguments: (block as ToolCall).arguments ?? {},
          });
        }
      }
    }
  }

  return toolCalls;
}
