/**
 * @fileoverview OpenAI Token Extraction
 *
 * Extracts token values from OpenAI API responses.
 *
 * OpenAI reports tokens in the response.completed event:
 * - input_tokens: Full context sent to model
 * - output_tokens: Generated output
 * - input_tokens_details.cached_tokens: (optional) Tokens read from cache
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { TokenExtractionError, type TokenSource } from '../types.js';

const logger = createLogger('token-extraction-openai');

/**
 * OpenAI usage from response.completed event.
 */
export interface OpenAIUsage {
  input_tokens?: number;
  output_tokens?: number;
  input_tokens_details?: {
    cached_tokens?: number;
  };
}

/**
 * Metadata required for extraction context.
 */
export interface ExtractionMeta {
  turn: number;
  sessionId: string;
}

/**
 * Extract tokens from OpenAI API response.
 *
 * @param usage - Usage from response.completed event
 * @param meta - Extraction context metadata
 * @param providerType - Provider type (defaults to 'openai', can be 'openai-codex')
 * @returns TokenSource with extracted values
 * @throws TokenExtractionError if usage is missing
 *
 * @example
 * const source = extractFromOpenAI(
 *   { input_tokens: 5000, output_tokens: 200 },
 *   { turn: 1, sessionId: 'sess_abc' }
 * );
 */
export function extractFromOpenAI(
  usage: OpenAIUsage | undefined | null,
  meta: ExtractionMeta,
  providerType: 'openai' | 'openai-codex' = 'openai'
): TokenSource {
  if (!usage) {
    throw new TokenExtractionError('OpenAI response missing usage data', {
      provider: providerType,
      turn: meta.turn,
      sessionId: meta.sessionId,
      hasPartialData: false,
    });
  }

  const now = new Date().toISOString();

  const rawInputTokens = usage.input_tokens ?? 0;
  const rawOutputTokens = usage.output_tokens ?? 0;
  // OpenAI can report cached_tokens in input_tokens_details
  const rawCacheReadTokens = usage.input_tokens_details?.cached_tokens ?? 0;
  // OpenAI doesn't report cache creation tokens
  const rawCacheCreationTokens = 0;

  logger.debug('[TOKEN-SOURCE] OpenAI extraction', {
    turn: meta.turn,
    provider: providerType,
    inputTokens: rawInputTokens,
    outputTokens: rawOutputTokens,
    cachedTokens: rawCacheReadTokens,
    hasUsage: true,
  });

  return {
    provider: providerType,
    timestamp: now,
    rawInputTokens,
    rawOutputTokens,
    rawCacheReadTokens,
    rawCacheCreationTokens,
  };
}
