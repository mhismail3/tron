/**
 * @fileoverview Token Usage Normalizer
 *
 * Handles the semantic differences in how different providers report token usage:
 *
 * | Provider    | inputTokens Means           | Cache Support                    |
 * |-------------|-----------------------------|---------------------------------|
 * | Anthropic   | Non-cached tokens (cumulative) | cache_read + cache_creation   |
 * | OpenAI      | FULL context sent           | cached_tokens                    |
 * | OpenAI Codex| FULL context sent           | None                             |
 * | Gemini      | FULL context sent           | None                             |
 *
 * IMPORTANT: For Anthropic, inputTokens is NOT per-turn new tokens!
 * It's the cumulative non-cached content (conversation history grows each turn).
 * Only the system prompt gets cached. We calculate delta using contextWindowTokens.
 *
 * This normalizer provides:
 * - newInputTokens: Per-turn new tokens (for stats line display)
 * - contextWindowTokens: Total context window size (for progress pill)
 * - rawInputTokens: Raw provider value (for billing/debugging)
 */

import type { TokenUsage, ProviderType } from '../types/messages.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('token-normalizer');

/**
 * Normalized token usage with semantic clarity for different UI components.
 */
export interface NormalizedTokenUsage {
  /** Per-turn NEW input tokens (for stats line display) */
  newInputTokens: number;
  /** Output tokens for this turn */
  outputTokens: number;
  /** Total context window size (for progress pill) */
  contextWindowTokens: number;
  /** Raw input tokens as reported by provider (for billing/debugging) */
  rawInputTokens: number;
  /** Tokens read from cache (Anthropic/OpenAI) */
  cacheReadTokens: number;
  /** Tokens written to cache (Anthropic only) */
  cacheCreationTokens: number;
}

/**
 * Normalize token usage from raw provider values.
 *
 * @param raw - Raw token usage from provider
 * @param providerType - The provider type (affects semantic interpretation)
 * @param previousContextSize - Previous context size for delta calculation (ALL providers)
 * @returns Normalized token usage with semantic clarity
 *
 * @example
 * // Anthropic with cache (delta calculated from contextWindowTokens)
 * normalizeTokenUsage({ inputTokens: 604, outputTokens: 100, cacheReadTokens: 8266 }, 'anthropic', 8768)
 * // => { newInputTokens: 102, contextWindowTokens: 8870, ... }
 *
 * @example
 * // OpenAI (inputTokens is full context - calculate delta)
 * normalizeTokenUsage({ inputTokens: 5000, outputTokens: 100 }, 'openai', 4000)
 * // => { newInputTokens: 1000, contextWindowTokens: 5000, ... }
 */
export function normalizeTokenUsage(
  raw: TokenUsage,
  providerType: ProviderType,
  previousContextSize: number
): NormalizedTokenUsage {
  const cacheRead = raw.cacheReadTokens ?? 0;
  const cacheCreation = raw.cacheCreationTokens ?? 0;

  // Calculate contextWindowTokens based on provider
  // For Anthropic: includes cached tokens
  // For others: just inputTokens
  const contextWindowTokens = providerType === 'anthropic'
    ? raw.inputTokens + cacheRead + cacheCreation
    : raw.inputTokens;

  // Calculate newInputTokens as delta from previous context (ALL providers)
  // This is the per-turn new tokens for display
  let newInputTokens: number;

  if (previousContextSize === 0) {
    // First turn: all tokens are "new"
    newInputTokens = contextWindowTokens;
  } else if (contextWindowTokens < previousContextSize) {
    // Context shrank (Codex summarization/truncation, or Anthropic cache eviction)
    // Report 0 new tokens and log warning
    newInputTokens = 0;
    logger.warn('Context shrank', {
      previousContextSize,
      currentContextSize: contextWindowTokens,
      delta: previousContextSize - contextWindowTokens,
      providerType,
    });
  } else {
    // Normal case: delta = current - previous
    newInputTokens = contextWindowTokens - previousContextSize;
  }

  return {
    newInputTokens,
    outputTokens: raw.outputTokens,
    contextWindowTokens,
    rawInputTokens: raw.inputTokens,
    cacheReadTokens: cacheRead,
    cacheCreationTokens: cacheCreation,
  };
}

/**
 * Detect provider type from model ID.
 * Used when providerType is not explicitly set on TokenUsage.
 *
 * @param modelId - The model identifier
 * @returns The detected provider type
 */
export function detectProviderType(modelId: string): ProviderType {
  const lowerModel = modelId.toLowerCase();

  if (lowerModel.includes('claude')) {
    return 'anthropic';
  }

  if (lowerModel.includes('codex') || lowerModel.includes('o1') || lowerModel.includes('o3') || lowerModel.includes('o4')) {
    return 'openai-codex';
  }

  if (lowerModel.includes('gpt') || lowerModel.startsWith('openai/')) {
    return 'openai';
  }

  if (lowerModel.includes('gemini') || lowerModel.startsWith('google/')) {
    return 'google';
  }

  // Default to anthropic (most common case)
  logger.debug('Unknown model, defaulting to anthropic provider type', { modelId });
  return 'anthropic';
}
