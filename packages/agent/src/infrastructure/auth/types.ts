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
 * Named account entry for multi-account support.
 * Stored in auth.json providers.anthropic.accounts[]
 */
export interface AccountEntry {
  label: string;
  oauth: OAuthTokens;
}

/**
 * Provider-specific authentication data
 * Each provider can have OAuth tokens and/or an API key
 */
export interface ProviderAuth {
  oauth?: OAuthTokens;
  apiKey?: string;
  /** Named accounts for multi-account support (takes priority over legacy oauth field) */
  accounts?: AccountEntry[];
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
export type ServiceId = 'brave' | 'exa' | string;

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
  | { type: 'oauth'; accessToken: string; refreshToken: string; expiresAt: number; accountLabel?: string }
  | { type: 'api_key'; apiKey: string };

