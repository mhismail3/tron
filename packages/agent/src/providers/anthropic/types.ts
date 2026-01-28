/**
 * @fileoverview Anthropic Provider Types and Constants
 *
 * Defines authentication, configuration, and model constants for the Anthropic provider.
 */

import type { RetryConfig } from '../../utils/retry.js';

// =============================================================================
// Authentication Types
// =============================================================================

/**
 * API key authentication for Anthropic
 */
export interface ApiKeyAuth {
  type: 'api_key';
  apiKey: string;
}

/**
 * OAuth authentication for Anthropic
 */
export interface OAuthAuth {
  type: 'oauth';
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

/**
 * Authentication options for Anthropic
 */
export type AnthropicAuth = ApiKeyAuth | OAuthAuth;

// =============================================================================
// Configuration Types
// =============================================================================

// Forward declaration to avoid circular imports
import type { AnthropicApiSettings, ModelSettings, RetrySettings } from '../../settings/types.js';

/**
 * Combined settings needed by AnthropicProvider.
 * This combines multiple settings sections for DI.
 */
export interface AnthropicProviderSettings {
  api: AnthropicApiSettings;
  models: ModelSettings;
  retry: RetrySettings;
}

/**
 * Configuration for Anthropic provider
 */
export interface AnthropicConfig {
  model: string;
  auth: AnthropicAuth;
  maxTokens?: number;
  temperature?: number;
  thinkingBudget?: number;
  baseURL?: string;
  /** Retry configuration for rate limits and transient errors */
  retry?: RetryConfig;
  /** Optional provider settings for dependency injection (falls back to global settings) */
  providerSettings?: AnthropicProviderSettings;
}

/**
 * Options for streaming requests
 */
export interface StreamOptions {
  maxTokens?: number;
  temperature?: number;
  enableThinking?: boolean;
  thinkingBudget?: number;
  stopSequences?: string[];
}

// =============================================================================
// Model Constants
// =============================================================================

/**
 * Claude model information
 */
export interface ClaudeModelInfo {
  name: string;
  contextWindow: number;
  maxOutput: number;
  supportsThinking: boolean;
  inputCostPer1k: number;
  outputCostPer1k: number;
}

export const CLAUDE_MODELS: Record<string, ClaudeModelInfo> = {
  // Claude 4.5 models (latest - Current Generation)
  'claude-opus-4-5-20251101': {
    name: 'Claude Opus 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.005,
    outputCostPer1k: 0.025,
  },
  'claude-sonnet-4-5-20250929': {
    name: 'Claude Sonnet 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  'claude-haiku-4-5-20251001': {
    name: 'Claude Haiku 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.001,
    outputCostPer1k: 0.005,
  },
  // Claude 4.1 models (Legacy - August 2025)
  'claude-opus-4-1-20250805': {
    name: 'Claude Opus 4.1',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  // Claude 4 models (Legacy - May 2025)
  'claude-opus-4-20250514': {
    name: 'Claude Opus 4',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  'claude-sonnet-4-20250514': {
    name: 'Claude Sonnet 4',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3.7 models (Legacy - February 2025)
  'claude-3-7-sonnet-20250219': {
    name: 'Claude 3.7 Sonnet',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3 Haiku (Legacy - oldest still available)
  'claude-3-haiku-20240307': {
    name: 'Claude 3 Haiku',
    contextWindow: 200000,
    maxOutput: 4000,
    supportsThinking: false,
    inputCostPer1k: 0.00025,
    outputCostPer1k: 0.00125,
  },
};

export type ClaudeModelId = keyof typeof CLAUDE_MODELS;

/** Default model for new sessions */
export const DEFAULT_MODEL = 'claude-opus-4-5-20251101' as ClaudeModelId;

// =============================================================================
// OAuth Constants
// =============================================================================

/**
 * System prompt prefix required for OAuth authentication.
 * Anthropic requires this identity statement for OAuth-authenticated requests.
 */
export const OAUTH_SYSTEM_PROMPT_PREFIX = "You are Claude Code, Anthropic's official CLI for Claude.";

/**
 * System prompt content block type for OAuth (uses cache control)
 */
export type SystemPromptBlock = {
  type: 'text';
  text: string;
  cache_control?: { type: 'ephemeral' };
};
