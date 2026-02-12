/**
 * @fileoverview Anthropic OAuth Authentication
 *
 * Handles OAuth token management for Anthropic including:
 * - Token refresh before expiry
 * - Token persistence to correct location (account vs provider)
 * - OAuth header construction with model-specific beta headers
 *
 * Extracted from anthropic-provider.ts for modularity and testability.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { shouldRefreshTokens, refreshOAuthToken, type OAuthTokens } from '@infrastructure/auth/oauth.js';
import { saveAccountOAuthTokens, saveProviderOAuthTokens } from '@infrastructure/auth/unified.js';
import type { AnthropicProviderSettings } from './types.js';
import { CLAUDE_MODELS } from './types.js';

const logger = createLogger('anthropic-auth');

// =============================================================================
// Types
// =============================================================================

export interface TokenRefreshResult {
  tokens: OAuthTokens;
  refreshed: boolean;
}

export interface TokenPersistenceConfig {
  accountLabel?: string;
}

// =============================================================================
// OAuth Headers
// =============================================================================

/**
 * Build OAuth headers for Anthropic API requests.
 *
 * Models that don't require thinking beta headers (e.g., Opus 4.6) only send
 * the base OAuth header. Models that do require them send all configured beta headers.
 */
export function getOAuthHeaders(
  model: string,
  providerSettings: AnthropicProviderSettings
): Record<string, string> {
  const modelInfo = CLAUDE_MODELS[model];
  const betaHeaders = (!modelInfo || modelInfo.requiresThinkingBetaHeaders)
    ? providerSettings.api.oauthBetaHeaders
    : 'oauth-2025-04-20';
  return {
    'accept': 'application/json',
    'anthropic-dangerous-direct-browser-access': 'true',
    'anthropic-beta': betaHeaders,
  };
}

// =============================================================================
// Token Management
// =============================================================================

/**
 * Ensure OAuth tokens are valid, refreshing if needed.
 *
 * @returns Updated tokens and whether a refresh occurred.
 *          If no refresh was needed, returns the original tokens.
 */
export async function ensureValidTokens(
  tokens: OAuthTokens,
  persistence: TokenPersistenceConfig = {}
): Promise<TokenRefreshResult> {
  if (!shouldRefreshTokens(tokens)) {
    return { tokens, refreshed: false };
  }

  logger.info('Refreshing expired OAuth tokens');
  const newTokens = await refreshOAuthToken(tokens.refreshToken);

  // Persist refreshed tokens to the correct location
  if (persistence.accountLabel) {
    await saveAccountOAuthTokens('anthropic', persistence.accountLabel, newTokens);
  } else {
    await saveProviderOAuthTokens('anthropic', newTokens);
  }

  return { tokens: newTokens, refreshed: true };
}
