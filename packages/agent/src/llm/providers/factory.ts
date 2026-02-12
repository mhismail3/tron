/**
 * @fileoverview Provider Factory
 *
 * Creates and manages providers with a unified interface.
 * Supports Anthropic (with OAuth), OpenAI (with OAuth), and Google providers.
 */

import type { Context, StreamEvent } from '@core/types/index.js';
import { AnthropicProvider, type AnthropicConfig, type StreamOptions } from './anthropic/index.js';
import {
  OpenAIProvider,
  type OpenAIConfig,
  type OpenAIStreamOptions,
  type ReasoningEffort,
  OPENAI_MODELS,
  DEFAULT_OPENAI_MODEL,
} from './openai/index.js';
import {
  GoogleProvider,
  type GoogleConfig,
  type GoogleStreamOptions,
  type GeminiThinkingLevel,
  type SafetySetting,
  type GoogleProviderAuth,
  type GoogleOAuthAuth,
  type GoogleApiKeyAuth,
} from './google/index.js';
import type { GoogleOAuthEndpoint } from '@infrastructure/auth/google-oauth.js';
import { CLAUDE_MODELS, DEFAULT_MODEL } from './anthropic/index.js';
import { GEMINI_MODELS } from './google/index.js';
import { DEFAULT_GOOGLE_MODEL } from './model-ids.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('provider-factory');

// =============================================================================
// Types
// =============================================================================

export type ProviderType = 'anthropic' | 'openai' | 'openai-codex' | 'google';

/**
 * Unified auth configuration
 */
export type UnifiedAuth =
  | { type: 'api_key'; apiKey: string }
  | { type: 'oauth'; accessToken: string; refreshToken: string; expiresAt: number; accountLabel?: string };

/**
 * Unified provider configuration
 */
export interface ProviderConfig {
  type: ProviderType;
  model: string;
  auth: UnifiedAuth;
  maxTokens?: number;
  temperature?: number;
  baseURL?: string;
  // Anthropic-specific
  thinkingBudget?: number;
  // OpenAI-specific
  reasoningEffort?: ReasoningEffort;
  // Google/Gemini-specific
  /** Thinking level for Gemini 3 models (minimal/low/medium/high) */
  thinkingLevel?: GeminiThinkingLevel;
  /** Thinking budget for Gemini 2.5 models (0-32768 tokens) */
  geminiThinkingBudget?: number;
  /** Safety settings for Gemini (defaults to OFF) */
  safetySettings?: SafetySetting[];
  /** Google OAuth endpoint (cloud-code-assist or antigravity) */
  googleEndpoint?: GoogleOAuthEndpoint;
}

/**
 * Unified provider interface
 */
export interface Provider {
  readonly id: string;
  readonly model: string;
  stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent>;
}

/**
 * Unified stream options
 */
export interface ProviderStreamOptions {
  maxTokens?: number;
  temperature?: number;
  stopSequences?: string[];
  // Anthropic-specific
  enableThinking?: boolean;
  thinkingBudget?: number;
  effortLevel?: string;
  // OpenAI-specific
  reasoningEffort?: ReasoningEffort;
  // Google/Gemini-specific
  topP?: number;
  topK?: number;
  /** Thinking level for Gemini 3 models */
  thinkingLevel?: GeminiThinkingLevel;
  /** Thinking budget for Gemini 2.5 models */
  geminiThinkingBudget?: number;
}

// =============================================================================
// Model Registry
// =============================================================================

/**
 * Combined model registry for all providers
 */
export const PROVIDER_MODELS = {
  anthropic: CLAUDE_MODELS,
  openai: OPENAI_MODELS,
  'openai-codex': OPENAI_MODELS,
  google: GEMINI_MODELS,
} as const;

/**
 * Get model metadata
 */
export function getModelInfo(provider: ProviderType, modelId: string) {
  const models = PROVIDER_MODELS[provider];
  return models[modelId as keyof typeof models] ?? null;
}

/**
 * Get all models for a provider
 */
export function getModelsForProvider(provider: ProviderType) {
  return PROVIDER_MODELS[provider] ?? {};
}

const PROVIDER_PREFIX_MAP: Record<string, ProviderType> = {
  anthropic: 'anthropic',
  openai: 'openai',
  'openai-codex': 'openai-codex',
  google: 'google',
};

function detectProviderByRegistry(modelId: string): ProviderType | null {
  const target = modelId.toLowerCase();
  const entries = Object.entries(PROVIDER_MODELS) as Array<[ProviderType, Record<string, unknown>]>;
  for (const [provider, models] of entries) {
    const hasMatch = Object.keys(models).some(modelKey => modelKey.toLowerCase() === target);
    if (hasMatch) {
      return provider;
    }
  }
  return null;
}

function isOpenAICodexModel(modelId: string): boolean {
  const lowerModel = modelId.toLowerCase();
  if (lowerModel.includes('codex')) {
    return true;
  }
  // o-series models map to the Codex provider family.
  return /^o(?:1|3|4)(?:[-\d]|$)/.test(lowerModel);
}

/**
 * Family-to-provider mapping for models not in the registry.
 * Each key is a model ID prefix; checked with startsWith.
 */
const PROVIDER_FAMILY_PREFIXES: Array<[string, ProviderType]> = [
  ['claude', 'anthropic'],
  ['gpt', 'openai'],
  ['gemini', 'google'],
];

function detectProviderByFamily(modelId: string): ProviderType | null {
  const lower = modelId.toLowerCase();
  // O-series codex models checked first (before generic gpt)
  if (isOpenAICodexModel(lower)) return 'openai-codex';
  for (const [prefix, provider] of PROVIDER_FAMILY_PREFIXES) {
    if (lower.startsWith(prefix)) return provider;
  }
  return null;
}

export interface DetectProviderOptions {
  /** When true, throws for models that match neither registry nor family prefix. */
  strict?: boolean;
}

/**
 * Detect provider from model ID
 *
 * Resolution order:
 * 1. Explicit provider prefix (e.g. "openai/gpt-5")
 * 2. Registry lookup (exact match against known models)
 * 3. Family prefix (e.g. "claude-*" → anthropic, "gpt-*" → openai, "gemini-*" → google)
 * 4. Default to 'anthropic' (or throw in strict mode)
 */
export function detectProviderFromModel(
  modelId: string,
  options?: DetectProviderOptions,
): ProviderType {
  const normalized = modelId.trim();
  if (!normalized) {
    if (options?.strict) throw new Error(`Unknown model: "${modelId}"`);
    return 'anthropic';
  }

  // 1. Explicit provider prefix has highest priority.
  const slashIndex = normalized.indexOf('/');
  if (slashIndex > 0) {
    const prefix = normalized.slice(0, slashIndex).toLowerCase();
    const unprefixedModel = normalized.slice(slashIndex + 1);
    const mapped = PROVIDER_PREFIX_MAP[prefix];
    if (mapped) {
      if (mapped === 'openai' && isOpenAICodexModel(unprefixedModel)) {
        return 'openai-codex';
      }
      return mapped;
    }
  }

  // 2. Exact model registry match.
  const registryMatch = detectProviderByRegistry(normalized);
  if (registryMatch) {
    if (registryMatch === 'openai' && isOpenAICodexModel(normalized)) {
      return 'openai-codex';
    }
    return registryMatch;
  }

  // 3. Family prefix match.
  const familyMatch = detectProviderByFamily(normalized);
  if (familyMatch) return familyMatch;

  // 4. Unknown model — warn and fall back (or throw in strict mode).
  if (options?.strict) {
    throw new Error(`Unknown model: "${modelId}" — not found in registry or known model families`);
  }
  logger.warn('Unknown model ID, falling back to anthropic', { modelId });
  return 'anthropic';
}

/**
 * Validate a model ID for diagnostics.
 *
 * Returns structured information about whether the model is recognized,
 * which provider it maps to, and whether it's in the known registry.
 */
export function validateModelId(modelId: string): {
  valid: boolean;
  provider?: ProviderType;
  inRegistry: boolean;
} {
  const normalized = modelId.trim();
  if (!normalized) return { valid: false, inRegistry: false };

  const registryMatch = detectProviderByRegistry(normalized);
  if (registryMatch) {
    return { valid: true, provider: registryMatch, inRegistry: true };
  }

  const familyMatch = detectProviderByFamily(normalized);
  if (familyMatch) {
    return { valid: true, provider: familyMatch, inRegistry: false };
  }

  return { valid: false, inRegistry: false };
}

/**
 * Get default model for a provider
 */
export function getDefaultModel(provider: ProviderType): string {
  switch (provider) {
    case 'anthropic':
      return DEFAULT_MODEL;
    case 'openai':
    case 'openai-codex':
      return DEFAULT_OPENAI_MODEL;
    case 'google':
      return DEFAULT_GOOGLE_MODEL;
    default:
      return DEFAULT_MODEL;
  }
}

// =============================================================================
// Provider Factory
// =============================================================================

/**
 * Create a provider instance based on configuration
 */
export function createProvider(config: ProviderConfig): Provider {
  logger.info('Creating provider', { type: config.type, model: config.model });

  switch (config.type) {
    case 'anthropic':
      return createAnthropicProvider(config);
    case 'openai':
    case 'openai-codex':
      return createOpenAIProvider(config);
    case 'google':
      return createGoogleProvider(config);
    default:
      throw new Error(`Unknown provider type: ${config.type}`);
  }
}

/**
 * Create Anthropic provider
 */
function createAnthropicProvider(config: ProviderConfig): Provider {
  const anthropicConfig: AnthropicConfig = {
    model: config.model,
    auth: config.auth,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
    thinkingBudget: config.thinkingBudget,
  };

  const provider = new AnthropicProvider(anthropicConfig);

  // Return wrapped provider with unified interface
  return {
    id: 'anthropic',
    get model() { return provider.model; },
    async *stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent> {
      const opts: StreamOptions = {
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        stopSequences: options?.stopSequences,
        enableThinking: options?.enableThinking,
        thinkingBudget: options?.thinkingBudget,
        effortLevel: options?.effortLevel,
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Create OpenAI provider (OAuth-based, for ChatGPT subscription)
 */
function createOpenAIProvider(config: ProviderConfig): Provider {
  if (config.auth.type !== 'oauth') {
    throw new Error('OpenAI requires OAuth authentication');
  }

  const openaiConfig: OpenAIConfig = {
    model: config.model,
    auth: config.auth,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
    reasoningEffort: config.reasoningEffort,
  };

  const provider = new OpenAIProvider(openaiConfig);

  return {
    id: 'openai',
    get model() { return provider.model; },
    async *stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent> {
      const opts: OpenAIStreamOptions = {
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        reasoningEffort: options?.reasoningEffort,
        stopSequences: options?.stopSequences,
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Create Google provider
 *
 * Supports both OAuth (Cloud Code Assist / Antigravity) and API key authentication.
 * OAuth is ALWAYS preferred when available.
 */
function createGoogleProvider(config: ProviderConfig): Provider {
  // Build Google-specific auth from unified auth
  let googleAuth: GoogleProviderAuth;

  if (config.auth.type === 'oauth') {
    // OAuth authentication - PREFERRED
    googleAuth = {
      type: 'oauth',
      accessToken: config.auth.accessToken,
      refreshToken: config.auth.refreshToken,
      expiresAt: config.auth.expiresAt,
      endpoint: config.googleEndpoint,
    } as GoogleOAuthAuth;
  } else {
    // API key authentication - fallback
    googleAuth = {
      type: 'api_key',
      apiKey: config.auth.apiKey,
    } as GoogleApiKeyAuth;
  }

  const googleConfig: GoogleConfig = {
    model: config.model,
    auth: googleAuth,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
    thinkingLevel: config.thinkingLevel,
    thinkingBudget: config.geminiThinkingBudget,
    safetySettings: config.safetySettings,
  };

  const provider = new GoogleProvider(googleConfig);

  return {
    id: 'google',
    get model() { return provider.model; },
    async *stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent> {
      const opts: GoogleStreamOptions = {
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        topP: options?.topP,
        topK: options?.topK,
        stopSequences: options?.stopSequences,
        thinkingLevel: options?.thinkingLevel,
        thinkingBudget: options?.geminiThinkingBudget,
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Validate that a model is supported by a provider.
 *
 * Returns true if the model is in the known registry for the provider,
 * or if the model ID follows expected naming patterns for the provider.
 */
export function isModelSupported(provider: ProviderType, modelId: string): boolean {
  const models = PROVIDER_MODELS[provider];

  if (modelId in models) return true;

  // Check via family detection — model belongs to the given provider if family matches
  const detected = detectProviderByFamily(modelId);
  return detected === provider;
}

/**
 * Get model capabilities
 */
export interface ModelCapabilities {
  supportsTools: boolean;
  supportsThinking: boolean;
  supportsStreaming: boolean;
  supportsEffort: boolean;
  effortLevels?: string[];
  defaultEffortLevel?: string;
  maxOutput: number;
  contextWindow: number;
}

export function getModelCapabilities(provider: ProviderType, modelId: string): ModelCapabilities {
  const info = getModelInfo(provider, modelId) as Record<string, unknown> | null;

  if (!info) {
    // Default capabilities
    return {
      supportsTools: true,
      supportsThinking: false,
      supportsStreaming: true,
      supportsEffort: false,
      maxOutput: 4096,
      contextWindow: 128000,
    };
  }

  // Anthropic uses supportsEffort/effortLevels/defaultEffortLevel
  // OpenAI uses supportsReasoning/reasoningLevels/defaultReasoningLevel
  const supportsEffort = (typeof info.supportsEffort === 'boolean' && info.supportsEffort) ||
    (typeof info.supportsReasoning === 'boolean' && info.supportsReasoning);
  const effortLevels = Array.isArray(info.effortLevels) ? info.effortLevels as string[]
    : Array.isArray(info.reasoningLevels) ? info.reasoningLevels as string[]
    : undefined;
  const defaultEffortLevel = typeof info.defaultEffortLevel === 'string' ? info.defaultEffortLevel
    : typeof info.defaultReasoningLevel === 'string' ? info.defaultReasoningLevel
    : undefined;

  return {
    supportsTools: typeof info.supportsTools === 'boolean' ? info.supportsTools : true,
    supportsThinking: typeof info.supportsThinking === 'boolean' ? info.supportsThinking : false,
    supportsStreaming: true,
    supportsEffort,
    effortLevels: supportsEffort ? effortLevels : undefined,
    defaultEffortLevel: supportsEffort ? defaultEffortLevel : undefined,
    maxOutput: typeof info.maxOutput === 'number' ? info.maxOutput : 4096,
    contextWindow: typeof info.contextWindow === 'number' ? info.contextWindow : 128000,
  };
}
