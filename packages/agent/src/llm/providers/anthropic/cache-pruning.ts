/**
 * @fileoverview Cache-TTL Pruning
 *
 * Pure functions for managing prompt cache efficiency after idle periods.
 * When the cache goes cold (>5m since last API call), large tool_result
 * blocks in old turns are pruned to reduce re-caching cost.
 */

import type Anthropic from '@anthropic-ai/sdk';

const DEFAULT_TTL_MS = 5 * 60 * 1000; // 5 minutes
const DEFAULT_RECENT_TURNS = 3;
const PRUNE_THRESHOLD_BYTES = 2048;

/**
 * Check if the prompt cache has gone cold based on elapsed time.
 *
 * Returns false for lastApiCallMs === 0 (no prior call — first request
 * should never prune since there's nothing cached).
 */
export function isCacheCold(lastApiCallMs: number, ttlMs: number = DEFAULT_TTL_MS): boolean {
  if (lastApiCallMs === 0) return false;
  return Date.now() - lastApiCallMs > ttlMs;
}

/**
 * Prune large tool_result content blocks from old turns.
 *
 * When the cache goes cold, we'll re-cache the entire conversation.
 * Pruning large tool_results from old turns reduces the number of
 * tokens that need to be written back to cache.
 *
 * Returns a NEW array — never mutates the input.
 *
 * @param messages - Anthropic-formatted messages
 * @param recentTurnsToPreserve - Number of recent assistant turns to keep intact
 */
export function pruneToolResultsForRecache(
  messages: Anthropic.Messages.MessageParam[],
  recentTurnsToPreserve: number = DEFAULT_RECENT_TURNS
): Anthropic.Messages.MessageParam[] {
  if (messages.length === 0) return [];

  // Count assistant messages to identify "turns"
  let assistantCount = 0;
  for (const msg of messages) {
    if (msg.role === 'assistant') assistantCount++;
  }

  // Walk backwards to find the cutoff index
  const preserveAfterTurn = assistantCount - recentTurnsToPreserve;
  if (preserveAfterTurn <= 0) return messages;

  let turnsSeen = 0;
  let cutoffIndex = messages.length;
  for (let i = 0; i < messages.length; i++) {
    if (messages[i]!.role === 'assistant') {
      turnsSeen++;
      if (turnsSeen > preserveAfterTurn) {
        cutoffIndex = i;
        break;
      }
    }
  }

  return messages.map((msg, i) => {
    if (i >= cutoffIndex) return msg;
    if (msg.role !== 'user' || !Array.isArray(msg.content)) return msg;

    let hasLargeToolResult = false;
    for (const block of msg.content) {
      if (
        typeof block === 'object' &&
        'type' in block &&
        block.type === 'tool_result' &&
        typeof (block as any).content === 'string' &&
        (block as any).content.length > PRUNE_THRESHOLD_BYTES
      ) {
        hasLargeToolResult = true;
        break;
      }
    }

    if (!hasLargeToolResult) return msg;

    // Deep-clone only the affected message
    const newContent = msg.content.map((block: any) => {
      if (
        typeof block === 'object' &&
        block.type === 'tool_result' &&
        typeof block.content === 'string' &&
        block.content.length > PRUNE_THRESHOLD_BYTES
      ) {
        return {
          ...block,
          content: `[pruned ${block.content.length} chars for cache efficiency]`,
        };
      }
      return block;
    });

    return { ...msg, content: newContent };
  });
}
