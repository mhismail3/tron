/**
 * @fileoverview Token Normalization Module
 *
 * Handles the semantic differences in how different providers report token usage:
 *
 * | Provider    | inputTokens Means              | Context Window Calculation                        |
 * |-------------|--------------------------------|---------------------------------------------------|
 * | Anthropic   | Non-cached tokens (new content)| inputTokens + cacheReadTokens + cacheCreation     |
 * | OpenAI      | Full context sent              | inputTokens                                       |
 * | OpenAI Codex| Full context sent              | inputTokens                                       |
 * | Google      | Full context sent              | inputTokens                                       |
 *
 * Anthropic Cache Tokens:
 * - inputTokens: New content not from cache
 * - cacheReadTokens: Content read from cache (part of context)
 * - cacheCreationTokens: Content being written to cache (part of context, costs 25% more)
 *
 * Total context = inputTokens + cacheReadTokens + cacheCreationTokens
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type {
  TokenSource,
  TokenMeta,
  TokenRecord,
  ComputedTokens,
  CalculationMethod,
} from '../types.js';

const logger = createLogger('token-normalization');

/**
 * Compute context window tokens based on provider.
 *
 * For Anthropic: inputTokens + cacheReadTokens + cacheCreationTokens
 * For others: inputTokens (already includes full context)
 *
 * IMPORTANT: Anthropic's three token fields are MUTUALLY EXCLUSIVE (no overlap):
 * - input_tokens: Tokens NOT involved in any cache operation
 * - cache_creation_input_tokens: Tokens being written TO cache (sent to model, stored)
 * - cache_read_input_tokens: Tokens read FROM cache (not counted in input_tokens)
 *
 * Total context = input_tokens + cache_creation + cache_read (no double counting)
 */
function computeContextWindow(source: TokenSource): {
  contextWindowTokens: number;
  calculationMethod: CalculationMethod;
} {
  if (source.provider === 'anthropic') {
    // Anthropic: Total context = input + cacheRead + cacheCreation (mutually exclusive)
    return {
      contextWindowTokens:
        source.rawInputTokens + source.rawCacheReadTokens + source.rawCacheCreationTokens,
      calculationMethod: 'anthropic_cache_aware',
    };
  }

  // OpenAI/Google/Codex: inputTokens IS the full context
  return {
    contextWindowTokens: source.rawInputTokens,
    calculationMethod: 'direct',
  };
}

/**
 * Calculate per-turn delta (new tokens this turn).
 */
function computeNewInputTokens(
  contextWindowTokens: number,
  previousBaseline: number
): number {
  if (previousBaseline === 0) {
    // First turn: all tokens are "new"
    return contextWindowTokens;
  }

  if (contextWindowTokens < previousBaseline) {
    // Context shrank (compaction/truncation/cache eviction)
    logger.info('[TOKEN-NORMALIZE] Context shrink detected', {
      previous: previousBaseline,
      current: contextWindowTokens,
      delta: previousBaseline - contextWindowTokens,
    });
    return 0;
  }

  // Normal case: delta = current - previous
  return contextWindowTokens - previousBaseline;
}

/**
 * Normalize token usage from raw provider values.
 *
 * @param source - Token source extracted from provider API response
 * @param previousBaseline - Previous context size for delta calculation
 * @param meta - Metadata for this token record
 * @returns Immutable TokenRecord with computed values
 *
 * @example
 * // Anthropic with cache
 * const record = normalizeTokens(
 *   { provider: 'anthropic', rawInputTokens: 604, rawCacheReadTokens: 8266, ... },
 *   8768,  // previous baseline
 *   { turn: 2, sessionId: 'sess_abc', ... }
 * );
 * // => record.computed.newInputTokens = 102 (delta)
 * // => record.computed.contextWindowTokens = 8870
 */
export function normalizeTokens(
  source: TokenSource,
  previousBaseline: number,
  meta: TokenMeta
): TokenRecord {
  // Compute context window based on provider
  const { contextWindowTokens, calculationMethod } = computeContextWindow(source);

  // Compute per-turn delta
  const newInputTokens = computeNewInputTokens(contextWindowTokens, previousBaseline);

  // Build computed values
  const computed: ComputedTokens = {
    contextWindowTokens,
    newInputTokens,
    previousContextBaseline: previousBaseline,
    calculationMethod,
  };

  // Update meta with normalization timestamp
  const updatedMeta: TokenMeta = {
    ...meta,
    normalizedAt: new Date().toISOString(),
  };

  // Create immutable record
  const record: TokenRecord = {
    source: Object.freeze({ ...source }),
    computed: Object.freeze(computed),
    meta: Object.freeze(updatedMeta),
  };

  // Freeze the entire record
  return Object.freeze(record);
}

/**
 * Detect provider type from model ID.
 * Used when providerType is not explicitly set.
 */
export function detectProviderFromModel(modelId: string): TokenSource['provider'] {
  const lowerModel = modelId.toLowerCase();

  if (lowerModel.includes('claude')) {
    return 'anthropic';
  }

  if (lowerModel.includes('codex') || lowerModel.startsWith('o1') || lowerModel.startsWith('o3') || lowerModel.startsWith('o4')) {
    return 'openai-codex';
  }

  if (lowerModel.includes('gpt') || lowerModel.includes('openai/')) {
    return 'openai';
  }

  if (lowerModel.includes('gemini') || lowerModel.includes('google/')) {
    return 'google';
  }

  // Default to anthropic for unknown models
  return 'anthropic';
}
