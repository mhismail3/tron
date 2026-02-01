/**
 * @fileoverview Unified auth types for all providers
 *
 * This module defines the canonical types for the unified auth.json schema
 * that supports multiple providers (Anthropic, OpenAI Codex, OpenAI, Google, etc.)
 */

// =============================================================================
// Core Auth Types
// =============================================================================

/**
 * OAuth token set common to all providers
 */
export interface OAuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // Unix timestamp in milliseconds
}

/**
 * Provider-specific authentication data
 * Each provider can have OAuth tokens and/or an API key
 */
export interface ProviderAuth {
  oauth?: OAuthTokens;
  apiKey?: string;
}

/**
 * Google-specific authentication data
 * Extends ProviderAuth with OAuth client credentials and endpoint configuration
 */
export interface GoogleProviderAuth extends ProviderAuth {
  /** OAuth client ID (loaded from auth.json or defaults) */
  clientId?: string;
  /** OAuth client secret (loaded from auth.json or defaults) */
  clientSecret?: string;
  /** Which OAuth endpoint to use */
  endpoint?: 'cloud-code-assist' | 'antigravity';
  /** Project ID for x-goog-user-project header */
  projectId?: string;
}

/**
 * Known provider identifiers (LLM providers only)
 * Extensible - new providers can be added as string keys
 */
export type ProviderId = 'anthropic' | 'openai-codex' | 'openai' | 'google' | string;

/**
 * Known service identifiers (external APIs, not LLM providers)
 */
export type ServiceId = 'brave' | string;

/**
 * External service configuration
 */
export interface ServiceAuth {
  /** Single API key (legacy, still supported) */
  apiKey?: string;
  /** Multiple API keys for rotation (takes precedence over apiKey) */
  apiKeys?: string[];
}

/**
 * Unified auth storage schema (v1)
 * Stored at ~/.tron/auth.json
 */
export interface AuthStorage {
  version: 1;
  /** LLM provider authentication (Anthropic, OpenAI, Google, etc.) */
  providers: Record<ProviderId, ProviderAuth>;
  /** External service API keys (Brave Search, etc.) */
  services?: Record<ServiceId, ServiceAuth>;
  lastUpdated: string; // ISO 8601 timestamp
}

// =============================================================================
// Server Auth Types (Runtime)
// =============================================================================

/**
 * Server-side authentication result
 * Uses a discriminated union for type safety at runtime
 */
export type ServerAuth =
  | { type: 'oauth'; accessToken: string; refreshToken: string; expiresAt: number }
  | { type: 'api_key'; apiKey: string };

// =============================================================================
// Legacy Types (For Reference / Migration)
// =============================================================================

/**
 * Legacy auth.json schema (pre-unified)
 * @deprecated Use UnifiedAuth instead
 */
export interface LegacyAnthropicAuth {
  tokens?: OAuthTokens;
  apiKey?: string;
  lastUpdated: string;
}

/**
 * Legacy codex-tokens.json schema (pre-unified)
 * @deprecated Use UnifiedAuth with 'openai-codex' provider instead
 */
export interface LegacyCodexTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}
