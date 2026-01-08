/**
 * @fileoverview Model Catalog
 *
 * Comprehensive model definitions with metadata for UI display.
 * Organized by provider and model family.
 *
 * Source: https://platform.claude.com/docs/en/about-claude/models/overview
 */

// =============================================================================
// Types
// =============================================================================

export interface ModelInfo {
  /** Model ID for API calls */
  id: string;
  /** Display name */
  name: string;
  /** Short name for compact display */
  shortName: string;
  /** Model family (e.g., "Claude 4.5", "Claude 4") */
  family: string;
  /** Tier: opus (most capable), sonnet (balanced), haiku (fast) */
  tier: 'opus' | 'sonnet' | 'haiku';
  /** Context window size in tokens */
  contextWindow: number;
  /** Maximum output tokens */
  maxOutput: number;
  /** Supports extended thinking */
  supportsThinking: boolean;
  /** Release date */
  releaseDate: string;
  /** Input cost per million tokens */
  inputCostPerMillion: number;
  /** Output cost per million tokens */
  outputCostPerMillion: number;
  /** Brief description */
  description: string;
  /** Whether this is the recommended model in its tier */
  recommended?: boolean;
  /** Whether this is a legacy/deprecated model */
  legacy?: boolean;
}

export interface ModelCategory {
  name: string;
  description: string;
  models: ModelInfo[];
}

// =============================================================================
// Anthropic Claude Models - Latest (4.5 Family)
// =============================================================================

export const ANTHROPIC_MODELS: ModelInfo[] = [
  // Claude 4.5 (Latest - Current Generation)
  {
    id: 'claude-opus-4-5-20251101',
    name: 'Claude Opus 4.5',
    shortName: 'Opus 4.5',
    family: 'Claude 4.5',
    tier: 'opus',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    releaseDate: '2025-11-01',
    inputCostPerMillion: 5,
    outputCostPerMillion: 25,
    description: 'Premium model combining maximum intelligence with practical performance.',
    recommended: true,
  },
  {
    id: 'claude-sonnet-4-5-20250929',
    name: 'Claude Sonnet 4.5',
    shortName: 'Sonnet 4.5',
    family: 'Claude 4.5',
    tier: 'sonnet',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    releaseDate: '2025-09-29',
    inputCostPerMillion: 3,
    outputCostPerMillion: 15,
    description: 'Smart model for complex agents and coding. Best balance of intelligence, speed, and cost.',
    recommended: true,
  },
  {
    id: 'claude-haiku-4-5-20251001',
    name: 'Claude Haiku 4.5',
    shortName: 'Haiku 4.5',
    family: 'Claude 4.5',
    tier: 'haiku',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    releaseDate: '2025-10-01',
    inputCostPerMillion: 1,
    outputCostPerMillion: 5,
    description: 'Fastest model with near-frontier intelligence.',
    recommended: true,
  },

  // Claude 4.1 (Legacy - August 2025)
  {
    id: 'claude-opus-4-1-20250805',
    name: 'Claude Opus 4.1',
    shortName: 'Opus 4.1',
    family: 'Claude 4.1',
    tier: 'opus',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    releaseDate: '2025-08-05',
    inputCostPerMillion: 15,
    outputCostPerMillion: 75,
    description: 'Previous Opus with enhanced agentic capabilities.',
    legacy: true,
  },

  // Claude 4 (Legacy - May 2025)
  {
    id: 'claude-opus-4-20250514',
    name: 'Claude Opus 4',
    shortName: 'Opus 4',
    family: 'Claude 4',
    tier: 'opus',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    releaseDate: '2025-05-14',
    inputCostPerMillion: 15,
    outputCostPerMillion: 75,
    description: 'Opus 4 with tool use and extended thinking.',
    legacy: true,
  },
  {
    id: 'claude-sonnet-4-20250514',
    name: 'Claude Sonnet 4',
    shortName: 'Sonnet 4',
    family: 'Claude 4',
    tier: 'sonnet',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    releaseDate: '2025-05-14',
    inputCostPerMillion: 3,
    outputCostPerMillion: 15,
    description: 'Fast and capable for everyday coding tasks.',
    legacy: true,
  },

  // Claude 3.7 (Legacy - February 2025)
  {
    id: 'claude-3-7-sonnet-20250219',
    name: 'Claude 3.7 Sonnet',
    shortName: '3.7 Sonnet',
    family: 'Claude 3.7',
    tier: 'sonnet',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    releaseDate: '2025-02-19',
    inputCostPerMillion: 3,
    outputCostPerMillion: 15,
    description: 'First model with extended thinking support.',
    legacy: true,
  },

  // Claude 3 Haiku (Legacy - oldest still available)
  {
    id: 'claude-3-haiku-20240307',
    name: 'Claude 3 Haiku',
    shortName: '3 Haiku',
    family: 'Claude 3',
    tier: 'haiku',
    contextWindow: 200000,
    maxOutput: 4000,
    supportsThinking: false,
    releaseDate: '2024-03-07',
    inputCostPerMillion: 0.25,
    outputCostPerMillion: 1.25,
    description: 'Legacy fast model. Consider upgrading to Haiku 4.5.',
    legacy: true,
  },
];

// =============================================================================
// Model Categories (for organized display)
// =============================================================================

export const ANTHROPIC_MODEL_CATEGORIES: ModelCategory[] = [
  {
    name: 'Latest',
    description: 'Most capable and up-to-date models',
    models: ANTHROPIC_MODELS.filter(m => m.family === 'Claude 4.5'),
  },
  {
    name: 'Legacy',
    description: 'Older model versions (still available)',
    models: ANTHROPIC_MODELS.filter(m => m.legacy === true),
  },
];

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get model info by ID
 */
export function getModelById(modelId: string): ModelInfo | undefined {
  return ANTHROPIC_MODELS.find(m => m.id === modelId);
}

/**
 * Get recommended model for a tier
 */
export function getRecommendedModel(tier: 'opus' | 'sonnet' | 'haiku'): ModelInfo {
  const model = ANTHROPIC_MODELS.find(m => m.tier === tier && m.recommended);
  if (model) return model;
  // Fallback to first model of tier
  return ANTHROPIC_MODELS.find(m => m.tier === tier)!;
}

/**
 * Get tier icon for display
 */
export function getTierIcon(tier: 'opus' | 'sonnet' | 'haiku'): string {
  switch (tier) {
    case 'opus': return '\u25C6\u25C6\u25C6';  // ◆◆◆ Most capable
    case 'sonnet': return '\u25C6\u25C6\u25C7';  // ◆◆◇ Balanced
    case 'haiku': return '\u25C6\u25C7\u25C7';   // ◆◇◇ Fast
  }
}

/**
 * Get tier label for display
 */
export function getTierLabel(tier: 'opus' | 'sonnet' | 'haiku'): string {
  switch (tier) {
    case 'opus': return 'Most Capable';
    case 'sonnet': return 'Balanced';
    case 'haiku': return 'Fast & Light';
  }
}

/**
 * Format context window for display
 */
export function formatContextWindow(tokens: number): string {
  if (tokens >= 1000000) {
    return `${(tokens / 1000000).toFixed(1)}M`;
  }
  return `${(tokens / 1000).toFixed(0)}K`;
}

/**
 * Format model pricing for display (per million tokens)
 */
export function formatModelPricing(costPerMillion: number): string {
  if (costPerMillion < 1) {
    return `$${costPerMillion.toFixed(2)}/M`;
  }
  return `$${costPerMillion}/M`;
}

/**
 * Get all models as a flat list
 */
export function getAllModels(): ModelInfo[] {
  return [...ANTHROPIC_MODELS];
}

/**
 * Check if a model ID is valid
 */
export function isValidModelId(modelId: string): boolean {
  return ANTHROPIC_MODELS.some(m => m.id === modelId);
}

/**
 * Calculate cost for given model and token counts.
 * Returns cost in USD.
 */
export function calculateCost(
  modelId: string,
  inputTokens: number,
  outputTokens: number
): number {
  const model = getModelById(modelId);
  if (model) {
    const inputCost = (model.inputCostPerMillion * inputTokens) / 1_000_000;
    const outputCost = (model.outputCostPerMillion * outputTokens) / 1_000_000;
    return inputCost + outputCost;
  }

  // Fallback: use sonnet pricing if model not found
  const fallbackInputCost = (3 * inputTokens) / 1_000_000;
  const fallbackOutputCost = (15 * outputTokens) / 1_000_000;
  return fallbackInputCost + fallbackOutputCost;
}
