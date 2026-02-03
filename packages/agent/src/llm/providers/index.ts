/**
 * @fileoverview Provider exports
 */

export {
  AnthropicProvider,
  CLAUDE_MODELS,
  DEFAULT_MODEL,
  type AnthropicAuth,
  type AnthropicConfig,
  type StreamOptions,
  type ClaudeModelId,
} from './anthropic/index.js';

export {
  OpenAIProvider,
  OPENAI_MODELS,
  type OpenAIConfig,
  type OpenAIStreamOptions,
  type OpenAIModelId,
  type ReasoningEffort,
  type OpenAIOAuth,
} from './openai/index.js';

export {
  GoogleProvider,
  GEMINI_MODELS,
  type GoogleConfig,
  type GoogleStreamOptions,
  type GeminiModelId,
} from './google/index.js';

// Unified provider factory and types
export {
  createProvider,
  detectProviderFromModel,
  getDefaultModel,
  getModelInfo,
  getModelsForProvider,
  getModelCapabilities,
  isModelSupported,
  PROVIDER_MODELS,
  type Provider,
  type ProviderConfig,
  type ProviderType,
  type ProviderStreamOptions,
  type UnifiedAuth,
  type ModelCapabilities,
} from './factory.js';

// Model catalog with rich metadata
export {
  ANTHROPIC_MODELS,
  ANTHROPIC_MODEL_CATEGORIES,
  getModelById,
  getRecommendedModel,
  getTierIcon,
  getTierLabel,
  formatContextWindow,
  formatModelPricing,
  getAllModels,
  isValidModelId,
  type ModelInfo,
  type ModelCategory,
} from './models.js';

// Token module is now in @infrastructure/tokens - re-export for convenience
export {
  normalizeTokens,
  detectProviderFromModel as detectProviderTypeFromModel,
  type TokenRecord,
  type TokenSource,
  type TokenMeta,
  type ComputedTokens,
} from '@infrastructure/tokens/index.js';
