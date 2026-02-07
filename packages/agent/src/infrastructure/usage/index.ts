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

import type { TokenUsage, Cost } from '@core/types/messages.js';
import {
  CLAUDE_OPUS_4_6,
  CLAUDE_OPUS_4_5,
  CLAUDE_SONNET_4_5,
  CLAUDE_HAIKU_4_5,
  CLAUDE_OPUS_4_1,
  CLAUDE_OPUS_4,
  CLAUDE_SONNET_4,
  CLAUDE_3_7_SONNET,
  CLAUDE_3_HAIKU,
  GEMINI_3_PRO_PREVIEW,
  GEMINI_3_FLASH_PREVIEW,
  GEMINI_2_5_PRO,
  GEMINI_2_5_FLASH,
} from '@llm/providers/model-ids.js';
import { detectProviderFromModel, getModelInfo } from '@llm/providers/factory.js';

// =============================================================================
// Pricing Configuration
// =============================================================================

/**
 * Pricing tiers per million tokens
 * Source: https://www.anthropic.com/pricing (2025)
 */
interface PricingTier {
  inputPerMillion: number;
  outputPerMillion: number;
  cacheWriteMultiplier: number;  // 1.25x for 5-min, 2x for 1-hour
  cacheReadMultiplier: number;   // 0.1x (90% discount)
}

const CLAUDE_PRICING: Record<string, PricingTier> = {
  // Claude 4.6 models (Latest)
  [CLAUDE_OPUS_4_6]: {
    inputPerMillion: 5,
    outputPerMillion: 25,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 4.5 models (Current Generation)
  [CLAUDE_OPUS_4_5]: {
    inputPerMillion: 5,
    outputPerMillion: 25,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  [CLAUDE_SONNET_4_5]: {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  [CLAUDE_HAIKU_4_5]: {
    inputPerMillion: 1,
    outputPerMillion: 5,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 4.1 models (Legacy - August 2025)
  [CLAUDE_OPUS_4_1]: {
    inputPerMillion: 15,
    outputPerMillion: 75,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 4 models (Legacy - May 2025)
  [CLAUDE_OPUS_4]: {
    inputPerMillion: 15,
    outputPerMillion: 75,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  [CLAUDE_SONNET_4]: {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 3.7 Sonnet (Legacy - February 2025)
  [CLAUDE_3_7_SONNET]: {
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
  // Claude 3 Haiku (Legacy)
  [CLAUDE_3_HAIKU]: {
    inputPerMillion: 0.25,
    outputPerMillion: 1.25,
    cacheWriteMultiplier: 1.25,
    cacheReadMultiplier: 0.1,
  },
};

const GOOGLE_PRICING: Record<string, PricingTier> = {
  // Gemini 3 models (preview)
  [GEMINI_3_PRO_PREVIEW]: {
    inputPerMillion: 1.25,
    outputPerMillion: 5,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
  [GEMINI_3_FLASH_PREVIEW]: {
    inputPerMillion: 0.075,
    outputPerMillion: 0.3,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
  // Gemini 2.5 models
  [GEMINI_2_5_PRO]: {
    inputPerMillion: 1.25,
    outputPerMillion: 5,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: 0.25,
  },
  [GEMINI_2_5_FLASH]: {
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
 * Build a PricingTier from an OpenAI model registry entry.
 */
function openAIPricingFromInfo(info: Record<string, unknown>): PricingTier | null {
  const input = info.inputCostPerMillion;
  const output = info.outputCostPerMillion;
  const cacheRead = info.cacheReadCostPerMillion;
  if (typeof input !== 'number' || typeof output !== 'number') return null;
  return {
    inputPerMillion: input,
    outputPerMillion: output,
    cacheWriteMultiplier: 1,
    cacheReadMultiplier: typeof cacheRead === 'number' && input > 0 ? cacheRead / input : 0.1,
  };
}

/**
 * Get pricing tier for a model
 */
export function getPricingTier(model: string): PricingTier {
  // Check Claude models
  if (model in CLAUDE_PRICING) {
    return CLAUDE_PRICING[model]!;
  }

  // Check Google models
  if (model in GOOGLE_PRICING) {
    return GOOGLE_PRICING[model]!;
  }

  // Check OpenAI models via registry
  const provider = detectProviderFromModel(model);
  if (provider === 'openai' || provider === 'openai-codex') {
    const info = getModelInfo(provider, model) as Record<string, unknown> | null;
    if (info) {
      const tier = openAIPricingFromInfo(info);
      if (tier) return tier;
    }
  }

  // Pattern matching for model families
  const modelLower = model.toLowerCase();

  if (modelLower.includes('opus-4-6') || modelLower.includes('opus-4.6')) {
    return CLAUDE_PRICING[CLAUDE_OPUS_4_6]!;
  }
  if (modelLower.includes('opus-4-5') || modelLower.includes('opus-4.5')) {
    return CLAUDE_PRICING[CLAUDE_OPUS_4_5]!;
  }
  if (modelLower.includes('opus')) {
    return CLAUDE_PRICING[CLAUDE_OPUS_4]!;
  }
  if (modelLower.includes('sonnet-4-5') || modelLower.includes('sonnet-4.5')) {
    return CLAUDE_PRICING[CLAUDE_SONNET_4_5]!;
  }
  if (modelLower.includes('sonnet')) {
    return CLAUDE_PRICING[CLAUDE_SONNET_4]!;
  }
  if (modelLower.includes('haiku-4-5') || modelLower.includes('haiku-4.5')) {
    return CLAUDE_PRICING[CLAUDE_HAIKU_4_5]!;
  }
  if (modelLower.includes('haiku')) {
    return CLAUDE_PRICING[CLAUDE_3_HAIKU]!;
  }
  if (modelLower.includes('gemini-2.5-pro')) {
    return GOOGLE_PRICING[GEMINI_2_5_PRO]!;
  }
  if (modelLower.includes('gemini')) {
    return GOOGLE_PRICING[GEMINI_2_5_FLASH]!;
  }

  // Default to Sonnet pricing (common middle-tier)
  return CLAUDE_PRICING[CLAUDE_SONNET_4]!;
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

/**
 * Get context limit for a model.
 * Derives from the canonical model registries — no hardcoded map.
 */
export function getContextLimit(model: string): number {
  const provider = detectProviderFromModel(model);
  const info = getModelInfo(provider, model) as Record<string, unknown> | null;
  if (info && typeof info.contextWindow === 'number') {
    return info.contextWindow;
  }
  return 200_000;
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
