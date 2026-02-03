/**
 * @fileoverview Anthropic Token Extraction
 *
 * Extracts token values from Anthropic API responses.
 *
 * Anthropic reports tokens in two events:
 * - message_start: input_tokens, cache_creation_input_tokens, cache_read_input_tokens
 * - message_delta: output_tokens
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { TokenExtractionError, type TokenSource } from '../types.js';

const logger = createLogger('token-extraction-anthropic');

/**
 * Anthropic usage from message_start event.
 */
export interface AnthropicMessageStartUsage {
  input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
}

/**
 * Anthropic usage from message_delta event.
 */
export interface AnthropicMessageDeltaUsage {
  output_tokens?: number;
}

/**
 * Metadata required for extraction context.
 */
export interface ExtractionMeta {
  turn: number;
  sessionId: string;
}

/**
 * Extract tokens from Anthropic API response events.
 *
 * @param messageStartUsage - Usage from message_start event
 * @param messageDeltaUsage - Usage from message_delta event
 * @param meta - Extraction context metadata
 * @returns TokenSource with extracted values
 * @throws TokenExtractionError if both usage objects are missing
 *
 * @example
 * const source = extractFromAnthropic(
 *   { input_tokens: 500, cache_read_input_tokens: 8000 },
 *   { output_tokens: 100 },
 *   { turn: 1, sessionId: 'sess_abc' }
 * );
 */
export function extractFromAnthropic(
  messageStartUsage: AnthropicMessageStartUsage | undefined | null,
  messageDeltaUsage: AnthropicMessageDeltaUsage | undefined | null,
  meta: ExtractionMeta
): TokenSource {
  // Both missing is an error - we can't extract anything
  if (!messageStartUsage && !messageDeltaUsage) {
    throw new TokenExtractionError('Anthropic response missing usage data in both message_start and message_delta', {
      provider: 'anthropic',
      turn: meta.turn,
      sessionId: meta.sessionId,
      hasPartialData: false,
    });
  }

  const now = new Date().toISOString();

  const rawInputTokens = messageStartUsage?.input_tokens ?? 0;
  const rawOutputTokens = messageDeltaUsage?.output_tokens ?? 0;
  const rawCacheReadTokens = messageStartUsage?.cache_read_input_tokens ?? 0;
  const rawCacheCreationTokens = messageStartUsage?.cache_creation_input_tokens ?? 0;

  // Log warning if input_tokens is 0 but we have cache tokens (unusual)
  if (rawInputTokens === 0 && (rawCacheReadTokens > 0 || rawCacheCreationTokens > 0)) {
    logger.warn('[TOKEN-EXTRACT] Anthropic input_tokens is 0 but cache tokens exist', {
      turn: meta.turn,
      sessionId: meta.sessionId,
      cacheRead: rawCacheReadTokens,
      cacheCreation: rawCacheCreationTokens,
    });
  }

  logger.debug('[TOKEN-SOURCE] Anthropic extraction', {
    turn: meta.turn,
    inputTokens: rawInputTokens,
    outputTokens: rawOutputTokens,
    cacheRead: rawCacheReadTokens,
    cacheCreation: rawCacheCreationTokens,
    hasMessageStart: !!messageStartUsage,
    hasMessageDelta: !!messageDeltaUsage,
  });

  return {
    provider: 'anthropic',
    timestamp: now,
    rawInputTokens,
    rawOutputTokens,
    rawCacheReadTokens,
    rawCacheCreationTokens,
  };
}
