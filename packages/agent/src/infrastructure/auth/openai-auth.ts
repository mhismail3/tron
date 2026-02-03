/**
 * @fileoverview OpenAI/Codex authentication loading
 *
 * Provides server-side auth loading for OpenAI Codex models with fallback
 * from OAuth to API key, matching the pattern used by Anthropic and Google.
 */

import { createLogger } from '../logging/index.js';
import { loadAuthStorage, saveProviderOAuthTokens } from './unified.js';
import type { ServerAuth } from './types.js';
import { createTokenExpiration } from './token-expiration.js';

const logger = createLogger('openai-auth');

// =============================================================================
// Constants
// =============================================================================

/** OpenAI token URL for refresh */
const OPENAI_TOKEN_URL = 'https://auth.openai.com/oauth/token';

/** OpenAI OAuth client ID (from Codex CLI) */
const OPENAI_CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';

// =============================================================================
// Token Refresh (for future use)
// =============================================================================

/**
 * Refresh OpenAI OAuth token
 *
 * Note: OpenAI Codex OAuth tokens currently have long expiry.
 * This is implemented for future-proofing.
 */
export async function refreshOpenAIToken(
  refreshToken: string
): Promise<{ accessToken: string; refreshToken: string; expiresAt: number }> {
  logger.info('Refreshing OpenAI OAuth token');

  const response = await fetch(OPENAI_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      client_id: OPENAI_CLIENT_ID,
      refresh_token: refreshToken,
    }),
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    const errorCode = (errorData as { error?: string }).error ?? 'unknown_error';
    logger.error('OpenAI token refresh failed', {
      status: response.status,
      error: errorCode,
    });
    throw new Error(`OpenAI token refresh failed: ${errorCode}`);
  }

  const data = (await response.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in: number;
  };

  // No buffer for OpenAI tokens (they handle expiry differently)
  const expiration = createTokenExpiration(data.expires_in, 0);

  logger.info('OpenAI token refresh successful', {
    expiresIn: data.expires_in,
    expiresAt: new Date(expiration.expiresAtMs).toISOString(),
  });

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? refreshToken,
    expiresAt: expiration.expiresAtMs,
  };
}

// =============================================================================
// Server-side Auth Loading
// =============================================================================

/**
 * Load authentication for OpenAI/Codex provider
 *
 * Priority:
 * 1. OPENAI_OAUTH_TOKEN env var (pre-configured OAuth token)
 * 2. OAuth tokens from ~/.tron/auth.json providers['openai-codex'].oauth (refreshed if needed)
 * 3. OPENAI_API_KEY env var (fallback)
 * 4. API key from ~/.tron/auth.json providers['openai-codex'].apiKey (last resort)
 * 5. null if no auth configured
 *
 * @returns ServerAuth if authenticated, null if login needed
 */
export async function loadOpenAIServerAuth(): Promise<ServerAuth | null> {
  // Priority 1: OAuth token from environment
  const envToken = process.env.OPENAI_OAUTH_TOKEN;
  if (envToken) {
    logger.info('Using OPENAI_OAUTH_TOKEN from environment');
    return {
      type: 'oauth',
      accessToken: envToken,
      refreshToken: '',
      expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000, // Assume 1 year validity
    };
  }

  // Load from unified auth.json
  const auth = await loadAuthStorage();
  const codexAuth = auth?.providers['openai-codex'];

  // Priority 2: OAuth tokens from auth.json (preferred for Codex subscription)
  if (codexAuth?.oauth) {
    const tokens = codexAuth.oauth;

    // Check if tokens need refresh (with 5 min buffer)
    const expiryBuffer = 300 * 1000; // 5 minutes in ms
    if (tokens.expiresAt - expiryBuffer < Date.now()) {
      logger.info('OpenAI OAuth tokens expired, attempting refresh...');
      try {
        const newTokens = await refreshOpenAIToken(tokens.refreshToken);

        // Save refreshed tokens back to unified auth
        await saveProviderOAuthTokens('openai-codex', {
          accessToken: newTokens.accessToken,
          refreshToken: newTokens.refreshToken,
          expiresAt: newTokens.expiresAt,
        });

        return {
          type: 'oauth',
          accessToken: newTokens.accessToken,
          refreshToken: newTokens.refreshToken,
          expiresAt: newTokens.expiresAt,
        };
      } catch (error) {
        logger.error('Failed to refresh OpenAI OAuth tokens', { error });
        // Fall through to API key fallback
      }
    } else {
      // Tokens are still valid
      return {
        type: 'oauth',
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
      };
    }
  }

  // Priority 3: API key from environment (fallback)
  const envApiKey = process.env.OPENAI_API_KEY;
  if (envApiKey) {
    logger.info('Using OPENAI_API_KEY from environment (fallback)');
    return {
      type: 'api_key',
      apiKey: envApiKey,
    };
  }

  // Priority 4: API key from auth.json (last resort)
  if (codexAuth?.apiKey) {
    logger.info('Using API key from auth.json for openai-codex (fallback)');
    return {
      type: 'api_key',
      apiKey: codexAuth.apiKey,
    };
  }

  logger.warn('No OpenAI/Codex authentication configured');
  return null;
}

