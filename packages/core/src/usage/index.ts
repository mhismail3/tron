/**
 * @fileoverview Token Usage and Cost Tracking
 *
 * Provides accurate token counting and cost calculation for LLM API calls.
 * Follows cccost's approach of tracking per-request usage and calculating
 * costs based on actual API response data.
 *
 * Key features:
 * - Per-request token tracking
 * - Cache token support (read/write)
 * - Accurate cost calculation with cache pricing
 * - Multi-provider support (extensible)
 */

import type { TokenUsage, Cost } from '../types/messages.js';

// =============================================================================
// Pricing Configuration
// =============================================================================

/**
 * Pricing tiers per million tokens
 * Source: https://www.anthropic.com/pricing (2025)
 */
export interface PricingTier {
  inputPerMillion: number;
  outputPerMillion: number;
  cacheWriteMultiplier: number;  // 1.25x for 5-min, 2x for 1-hour
  cacheReadMultiplier: number;   // 0.1x (90% discount)
}

export const CLAUDE_PRICING: Record<string, PricingTier> = {
  // Claude 4.5 models (Current Generation)
  // Source: https://platform.claude.com/docs/en/about-claude/models/overview
  'claude-opus-4-5-20251101': {
    inputPerMillion: 5,
    outputPerMillion: 25,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  'claude-sonnet-4-5-20250929': {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  'claude-haiku-4-5-20251001': {
    inputPerMillion: 1,
    outputPerMillion: 5,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 4.1 models (Legacy - August 2025)
  'claude-opus-4-1-20250805': {
    inputPerMillion: 15,
    outputPerMillion: 75,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 4 models (Legacy - May 2025)
  'claude-opus-4-20250514': {
    inputPerMillion: 15,
    outputPerMillion: 75,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  'claude-sonnet-4-20250514': {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 3.7 Sonnet (Legacy - February 2025)
  'claude-3-7-sonnet-20250219': {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 3 Haiku (Legacy)
  'claude-3-haiku-20240307': {
    inputPerMillion: 0.25,
    outputPerMillion: 1.25,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
};

export const OPENAI_PRICING: Record<string, PricingTier> = {
  'gpt-4o': {
    inputPerMillion: 2.5,
    outputPerMillion: 10,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.5, // OpenAI's cached rate
  },
  'gpt-4o-mini': {
    inputPerMillion: 0.15,
    outputPerMillion: 0.6,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.5,
  },
  'gpt-4-turbo': {
    inputPerMillion: 10,
    outputPerMillion: 30,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 1,
  },
};

export const GOOGLE_PRICING: Record<string, PricingTier> = {
  'gemini-2.0-flash': {
    inputPerMillion: 0.1,
    outputPerMillion: 0.4,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
  'gemini-2.5-pro': {
    inputPerMillion: 1.25,
    outputPerMillion: 5,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
  'gemini-2.5-flash': {
    inputPerMillion: 0.075,
    outputPerMillion: 0.3,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
};

// =============================================================================
// Usage Tracker
// =============================================================================

/**
 * Detailed usage for a single API request
 */
export interface RequestUsage {
  timestamp: Date;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  cost: Cost;
}

/**
 * Accumulated usage for a session
 */
export interface SessionUsage {
  requestCount: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCacheCreationTokens: number;
  totalCacheReadTokens: number;
  totalCost: Cost;
  requests: RequestUsage[];
}

/**
 * Get pricing tier for a model
 */
export function getPricingTier(model: string): PricingTier {
  // Check Claude models
  if (model in CLAUDE_PRICING) {
    return CLAUDE_PRICING[model]!;
  }

  // Check OpenAI models
  if (model in OPENAI_PRICING) {
    return OPENAI_PRICING[model]!;
  }

  // Check Google models
  if (model in GOOGLE_PRICING) {
    return GOOGLE_PRICING[model]!;
  }

  // Pattern matching for model families
  const modelLower = model.toLowerCase();

  if (modelLower.includes('opus-4-5') || modelLower.includes('opus-4.5')) {
    return CLAUDE_PRICING['claude-opus-4-5-20251101']!;
  }
  if (modelLower.includes('opus')) {
    return CLAUDE_PRICING['claude-opus-4-20250514']!;
  }
  if (modelLower.includes('sonnet-4-5') || modelLower.includes('sonnet-4.5')) {
    return CLAUDE_PRICING['claude-sonnet-4-5-20250929']!;
  }
  if (modelLower.includes('sonnet')) {
    return CLAUDE_PRICING['claude-sonnet-4-20250514']!;
  }
  if (modelLower.includes('haiku-4-5') || modelLower.includes('haiku-4.5')) {
    return CLAUDE_PRICING['claude-haiku-4-5-20251001']!;
  }
  if (modelLower.includes('haiku')) {
    return CLAUDE_PRICING['claude-3-haiku-20240307']!;
  }
  if (modelLower.includes('gpt-4o-mini')) {
    return OPENAI_PRICING['gpt-4o-mini']!;
  }
  if (modelLower.includes('gpt-4o')) {
    return OPENAI_PRICING['gpt-4o']!;
  }
  if (modelLower.includes('gpt-4')) {
    return OPENAI_PRICING['gpt-4-turbo']!;
  }
  if (modelLower.includes('gemini-2.5-pro')) {
    return GOOGLE_PRICING['gemini-2.5-pro']!;
  }
  if (modelLower.includes('gemini')) {
    return GOOGLE_PRICING['gemini-2.5-flash']!;
  }

  // Default to Sonnet pricing (common middle-tier)
  return CLAUDE_PRICING['claude-sonnet-4-20250514']!;
}

/**
 * Calculate cost for a single request
 */
export function calculateCost(
  model: string,
  usage: TokenUsage
): Cost {
  const pricing = getPricingTier(model);

  const inputTokens = usage.inputTokens;
  const outputTokens = usage.outputTokens;
  const cacheCreationTokens = usage.cacheCreationTokens ?? 0;
  const cacheReadTokens = usage.cacheReadTokens ?? 0;

  // Calculate input cost components
  // Base input tokens (excluding cache tokens which are billed separately)
  // Use max(0) to handle edge cases where cache tokens might exceed reported input
  const baseInputTokens = Math.max(0, inputTokens - cacheReadTokens - cacheCreationTokens);
  const baseInputCost = (baseInputTokens / 1_000_000) * pricing.inputPerMillion;

  // Cache creation cost (higher rate)
  const cacheCreationCost = (cacheCreationTokens / 1_000_000) *
    pricing.inputPerMillion * pricing.cacheWriteMultiplier;

  // Cache read cost (discounted rate)
  const cacheReadCost = (cacheReadTokens / 1_000_000) *
    pricing.inputPerMillion * pricing.cacheReadMultiplier;

  const totalInputCost = baseInputCost + cacheCreationCost + cacheReadCost;

  // Calculate output cost
  const outputCost = (outputTokens / 1_000_000) * pricing.outputPerMillion;

  return {
    inputCost: totalInputCost,
    outputCost,
    total: totalInputCost + outputCost,
    currency: 'USD',
  };
}

/**
 * Format cost as display string
 */
export function formatCost(cost: Cost | number): string {
  const total = typeof cost === 'number' ? cost : cost.total;
  if (total < 0.001) return '$0.00';
  if (total < 0.01) return `$${total.toFixed(3)}`;
  return `$${total.toFixed(2)}`;
}

/**
 * Format token count for display
 */
export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}K`;
  return n.toString();
}

/**
 * Create an empty usage tracker state
 */
export function createSessionUsage(): SessionUsage {
  return {
    requestCount: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheCreationTokens: 0,
    totalCacheReadTokens: 0,
    totalCost: {
      inputCost: 0,
      outputCost: 0,
      total: 0,
      currency: 'USD',
    },
    requests: [],
  };
}

/**
 * Add a request's usage to the session total
 */
export function addRequestUsage(
  session: SessionUsage,
  model: string,
  usage: TokenUsage
): SessionUsage {
  const cost = calculateCost(model, usage);

  const request: RequestUsage = {
    timestamp: new Date(),
    model,
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    cacheCreationTokens: usage.cacheCreationTokens ?? 0,
    cacheReadTokens: usage.cacheReadTokens ?? 0,
    cost,
  };

  return {
    requestCount: session.requestCount + 1,
    totalInputTokens: session.totalInputTokens + usage.inputTokens,
    totalOutputTokens: session.totalOutputTokens + usage.outputTokens,
    totalCacheCreationTokens: session.totalCacheCreationTokens + (usage.cacheCreationTokens ?? 0),
    totalCacheReadTokens: session.totalCacheReadTokens + (usage.cacheReadTokens ?? 0),
    totalCost: {
      inputCost: session.totalCost.inputCost + cost.inputCost,
      outputCost: session.totalCost.outputCost + cost.outputCost,
      total: session.totalCost.total + cost.total,
      currency: 'USD',
    },
    requests: [...session.requests, request],
  };
}

/**
 * Merge TokenUsage from agent turn result
 * Use this when you have a cumulative value and need to get the delta
 */
export function getUsageDelta(
  previous: TokenUsage,
  current: TokenUsage
): TokenUsage {
  return {
    inputTokens: current.inputTokens - previous.inputTokens,
    outputTokens: current.outputTokens - previous.outputTokens,
    cacheCreationTokens: (current.cacheCreationTokens ?? 0) - (previous.cacheCreationTokens ?? 0),
    cacheReadTokens: (current.cacheReadTokens ?? 0) - (previous.cacheReadTokens ?? 0),
  };
}

// =============================================================================
// Context Limit Utilities
// =============================================================================

export const CONTEXT_LIMITS: Record<string, number> = {
  // Claude 4.5 models
  'claude-opus-4-5-20251101': 200_000,
  'claude-sonnet-4-5-20250929': 200_000,
  'claude-haiku-4-5-20251001': 200_000,
  // Legacy Claude models
  'claude-opus-4-1-20250805': 200_000,
  'claude-opus-4-20250514': 200_000,
  'claude-sonnet-4-20250514': 200_000,
  'claude-3-7-sonnet-20250219': 200_000,
  'claude-3-haiku-20240307': 200_000,
  // OpenAI
  'gpt-4o': 128_000,
  'gpt-4o-mini': 128_000,
  'gpt-4-turbo': 128_000,
  // Google
  'gemini-2.5-pro': 1_000_000,
  'gemini-2.5-flash': 1_000_000,
  'gemini-2.0-flash': 1_000_000,
};

/**
 * Get context limit for a model
 */
export function getContextLimit(model: string): number {
  if (model in CONTEXT_LIMITS) {
    return CONTEXT_LIMITS[model]!;
  }

  const modelLower = model.toLowerCase();
  if (modelLower.includes('gemini')) return 1_000_000;
  if (modelLower.includes('gpt')) return 128_000;
  return 200_000; // Default Claude limit
}

/**
 * Calculate context usage percentage
 * @param currentContextTokens - Estimated tokens in current context (not cumulative)
 * @param model - Model ID for limit lookup
 */
export function getContextPercentage(currentContextTokens: number, model: string): number {
  const limit = getContextLimit(model);
  if (limit === 0) return 0;
  return Math.round((currentContextTokens / limit) * 100);
}
