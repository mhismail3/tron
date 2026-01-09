/**
 * @fileoverview Provider Factory
 *
 * Creates and manages providers with a unified interface.
 * Supports Anthropic (with OAuth), OpenAI, and Google providers.
 */

import type { Context, StreamEvent } from '../types/index.js';
import { AnthropicProvider, type AnthropicConfig, type StreamOptions } from './anthropic.js';
import { OpenAIProvider, type OpenAIConfig, type OpenAIStreamOptions } from './openai.js';
import { GoogleProvider, type GoogleConfig, type GoogleStreamOptions } from './google.js';
import {
  OpenAICodexProvider,
  type OpenAICodexConfig,
  type OpenAICodexStreamOptions,
  type ReasoningEffort,
  OPENAI_CODEX_MODELS,
} from './openai-codex.js';
import { CLAUDE_MODELS, DEFAULT_MODEL } from './anthropic.js';
import { OPENAI_MODELS } from './openai.js';
import { GEMINI_MODELS } from './google.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('provider-factory');

// =============================================================================
// Types
// =============================================================================

export type ProviderType = 'anthropic' | 'openai' | 'google' | 'openai-codex';

/**
 * Unified auth configuration
 */
export type UnifiedAuth =
  | { type: 'api_key'; apiKey: string }
  | { type: 'oauth'; accessToken: string; refreshToken: string; expiresAt: number };

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
  organization?: string;
  // OpenAI Codex-specific
  reasoningEffort?: ReasoningEffort;
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
  // OpenAI-specific
  topP?: number;
  frequencyPenalty?: number;
  presencePenalty?: number;
  // Google-specific
  topK?: number;
  // OpenAI Codex-specific
  reasoningEffort?: ReasoningEffort;
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
  google: GEMINI_MODELS,
  'openai-codex': OPENAI_CODEX_MODELS,
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

/**
 * Detect provider from model ID
 */
export function detectProviderFromModel(modelId: string): ProviderType {
  if (modelId.startsWith('claude') || modelId.includes('claude')) {
    return 'anthropic';
  }
  // OpenAI Codex models (via ChatGPT subscription)
  if (modelId.includes('codex')) {
    return 'openai-codex';
  }
  if (modelId.startsWith('gpt') || modelId.startsWith('o1') || modelId.startsWith('o3') || modelId.startsWith('o4')) {
    return 'openai';
  }
  if (modelId.startsWith('gemini')) {
    return 'google';
  }
  // Default to Anthropic
  return 'anthropic';
}

/**
 * Get default model for a provider
 */
export function getDefaultModel(provider: ProviderType): string {
  switch (provider) {
    case 'anthropic':
      return DEFAULT_MODEL;
    case 'openai':
      return 'gpt-4o';
    case 'google':
      return 'gemini-2.5-flash';
    case 'openai-codex':
      return 'gpt-5.2-codex';
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
      return createOpenAIProvider(config);
    case 'google':
      return createGoogleProvider(config);
    case 'openai-codex':
      return createOpenAICodexProvider(config);
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
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Create OpenAI provider
 */
function createOpenAIProvider(config: ProviderConfig): Provider {
  if (config.auth.type !== 'api_key') {
    throw new Error('OpenAI only supports API key authentication');
  }

  const openaiConfig: OpenAIConfig = {
    model: config.model,
    apiKey: config.auth.apiKey,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
    organization: config.organization,
  };

  const provider = new OpenAIProvider(openaiConfig);

  return {
    id: 'openai',
    get model() { return provider.model; },
    async *stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent> {
      const opts: OpenAIStreamOptions = {
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        topP: options?.topP,
        frequencyPenalty: options?.frequencyPenalty,
        presencePenalty: options?.presencePenalty,
        stopSequences: options?.stopSequences,
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Create Google provider
 */
function createGoogleProvider(config: ProviderConfig): Provider {
  if (config.auth.type !== 'api_key') {
    throw new Error('Google only supports API key authentication');
  }

  const googleConfig: GoogleConfig = {
    model: config.model,
    apiKey: config.auth.apiKey,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
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
      };
      yield* provider.stream(context, opts);
    },
  };
}

/**
 * Create OpenAI Codex provider (for ChatGPT subscription OAuth)
 */
function createOpenAICodexProvider(config: ProviderConfig): Provider {
  if (config.auth.type !== 'oauth') {
    throw new Error('OpenAI Codex requires OAuth authentication');
  }

  const codexConfig: OpenAICodexConfig = {
    model: config.model,
    auth: config.auth,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    baseURL: config.baseURL,
    reasoningEffort: config.reasoningEffort,
  };

  const provider = new OpenAICodexProvider(codexConfig);

  return {
    id: 'openai-codex',
    get model() { return provider.model; },
    async *stream(context: Context, options?: ProviderStreamOptions): AsyncGenerator<StreamEvent> {
      const opts: OpenAICodexStreamOptions = {
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
 * Validate that a model is supported by a provider
 */
export function isModelSupported(provider: ProviderType, modelId: string): boolean {
  const models = PROVIDER_MODELS[provider];
  // Check for exact match or known model patterns
  if (modelId in models) {
    return true;
  }
  // Allow any model string for flexibility (custom/new models)
  return true;
}

/**
 * Get model capabilities
 */
export interface ModelCapabilities {
  supportsTools: boolean;
  supportsThinking: boolean;
  supportsStreaming: boolean;
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
      maxOutput: 4096,
      contextWindow: 128000,
    };
  }

  return {
    supportsTools: typeof info.supportsTools === 'boolean' ? info.supportsTools : true,
    supportsThinking: typeof info.supportsThinking === 'boolean' ? info.supportsThinking : false,
    supportsStreaming: true,
    maxOutput: typeof info.maxOutput === 'number' ? info.maxOutput : 4096,
    contextWindow: typeof info.contextWindow === 'number' ? info.contextWindow : 128000,
  };
}
