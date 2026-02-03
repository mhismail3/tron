/**
 * @fileoverview Token Usage Normalizer
 *
 * Handles the semantic differences in how different providers report token usage:
 *
 * | Provider    | inputTokens Means              | Cache Support                  |
 * |-------------|--------------------------------|--------------------------------|
 * | Anthropic   | Non-cached tokens (cumulative) | cache_read + cache_creation    |
 * | OpenAI      | FULL context sent              | cached_tokens                  |
 * | OpenAI Codex| FULL context sent              | None                           |
 * | Gemini      | FULL context sent              | None                           |
 *
 * ============================================================================
 * CRITICAL: ANTHROPIC TOKEN SEMANTICS (common source of bugs)
 * ============================================================================
 *
 * For Anthropic, inputTokens is NOT the full context and NOT per-turn new tokens!
 *
 * What actually happens with Anthropic prompt caching:
 * 1. System prompt is cached (cache_create on first turn, cache_read thereafter)
 * 2. Conversation history is NOT cached - grows each turn in inputTokens
 * 3. inputTokens = cumulative non-cached content (excludes cached system prompt)
 *
 * IMPORTANT: cacheCreationTokens is a BILLING indicator, NOT additional context!
 * It tells you how many of your inputTokens are being written to cache (costs 25% more).
 * It does NOT add to the context window size.
 *
 * Example session:
 *   Turn 1: inputTokens=500,  cache_create=8000 → contextWindow = 500 + 0 = 500
 *           (cache_create=8000 means 8000 tokens are being cached for future reads)
 *   Turn 2: inputTokens=600,  cache_read=8000   → contextWindow = 600 + 8000 = 8600
 *   Turn 3: inputTokens=700,  cache_read=8000   → contextWindow = 700 + 8000 = 8700
 *
 * To get the full context size: inputTokens + cacheRead (NOT + cacheCreate!)
 * To get per-turn delta: currentContextWindow - previousContextWindow
 *
 * A common bug is including cacheCreationTokens in context window calculation.
 * This is WRONG because cache_creation is a subset of inputTokens for billing.
 *
 * ============================================================================
 *
 * This normalizer provides:
 * - newInputTokens: Per-turn new tokens (for stats line display)
 * - contextWindowTokens: Total context window size (for progress pill)
 * - rawInputTokens: Raw provider value (for billing/debugging)
 */

import type { TokenUsage, ProviderType } from '@core/types/messages.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { detectProviderFromModel } from './factory.js';

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
  // For Anthropic: inputTokens + cacheRead (NOT + cacheCreation!)
  //   - inputTokens = non-cached tokens sent to model
  //   - cacheRead = tokens read from cache (part of context)
  //   - cacheCreation = billing indicator, NOT additional context
  // For others: just inputTokens (full context)
  const contextWindowTokens = providerType === 'anthropic'
    ? raw.inputTokens + cacheRead
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
 * Re-exports detectProviderFromModel from factory.ts with the expected name.
 * This avoids code duplication while maintaining the expected API.
 *
 * @param modelId - The model identifier
 * @returns The detected provider type
 */
export function detectProviderType(modelId: string): ProviderType {
  return detectProviderFromModel(modelId);
}
