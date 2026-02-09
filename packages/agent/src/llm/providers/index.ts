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
  validateModelId,
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
  type DetectProviderOptions,
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

// Centralized model ID constants
export {
  CLAUDE_OPUS_4_6,
  CLAUDE_OPUS_4_5,
  CLAUDE_SONNET_4_5,
  CLAUDE_HAIKU_4_5,
  CLAUDE_OPUS_4_1,
  CLAUDE_OPUS_4,
  CLAUDE_SONNET_4,
  CLAUDE_3_7_SONNET,
  CLAUDE_3_HAIKU,
  GPT_5_3_CODEX,
  GPT_5_2_CODEX,
  GEMINI_3_PRO_PREVIEW,
  GEMINI_3_FLASH_PREVIEW,
  GEMINI_2_5_PRO,
  GEMINI_2_5_FLASH,
  GEMINI_2_5_FLASH_LITE,
  SUBAGENT_MODEL,
  DEFAULT_API_MODEL,
  DEFAULT_SERVER_MODEL,
  DEFAULT_GOOGLE_MODEL,
} from './model-ids.js';

// Token module is now in @infrastructure/tokens - re-export for convenience
export {
  normalizeTokens,
  detectProviderFromModel as detectProviderTypeFromModel,
  type TokenRecord,
  type TokenSource,
  type TokenMeta,
  type ComputedTokens,
} from '@infrastructure/tokens/index.js';
