/**
 * @fileoverview OpenAI OAuth Authentication
 *
 * Handles OAuth token management for OpenAI including:
 * - Token refresh before expiry
 * - JWT account ID extraction
 * - Token persistence
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { saveProviderOAuthTokens, type OAuthTokens } from '@infrastructure/auth/index.js';
import type { OpenAIOAuth, OpenAIApiSettings } from './types.js';

const logger = createLogger('openai-auth');

/**
 * Default OAuth settings
 */
const DEFAULT_TOKEN_URL = 'https://auth.openai.com/oauth/token';
const DEFAULT_CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';
const DEFAULT_TOKEN_EXPIRY_BUFFER_SECONDS = 300;

/**
 * Extract account ID from JWT token
 */
export function extractAccountId(token: string): string {
  try {
    const parts = token.split('.');
    if (parts.length < 2 || !parts[1]) {
      return '';
    }
    const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString()) as Record<string, unknown>;
    const authClaims = (payload['https://api.openai.com/auth'] ?? {}) as Record<string, unknown>;
    return (authClaims.chatgpt_account_id ?? '') as string;
  } catch (error) {
    logger.warn('Failed to extract account ID from JWT', { error });
    return '';
  }
}

/**
 * Check if tokens need refresh
 */
export function shouldRefreshTokens(
  expiresAt: number,
  settings?: OpenAIApiSettings
): boolean {
  const bufferSeconds = settings?.tokenExpiryBufferSeconds ?? DEFAULT_TOKEN_EXPIRY_BUFFER_SECONDS;
  // expiresAt is in milliseconds from our auth flow
  return Date.now() > expiresAt - (bufferSeconds * 1000);
}

/**
 * Refresh OAuth tokens
 */
export async function refreshTokens(
  refreshToken: string,
  settings?: OpenAIApiSettings
): Promise<OAuthTokens> {
  const tokenUrl = settings?.tokenUrl ?? DEFAULT_TOKEN_URL;
  const clientId = settings?.clientId ?? DEFAULT_CLIENT_ID;

  logger.info('Refreshing OpenAI OAuth tokens');

  const response = await fetch(tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: clientId,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Token refresh failed: ${response.status} - ${error}`);
  }

  const data = await response.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  const newTokens: OAuthTokens = {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt: Date.now() + data.expires_in * 1000,
  };

  // Persist refreshed tokens to disk
  await saveProviderOAuthTokens('openai-codex', newTokens);
  logger.info('Persisted refreshed OpenAI OAuth tokens');

  return newTokens;
}

/**
 * Token manager for maintaining valid OAuth tokens
 */
export class OpenAITokenManager {
  private auth: OpenAIOAuth;
  private settings?: OpenAIApiSettings;

  constructor(auth: OpenAIOAuth, settings?: OpenAIApiSettings) {
    this.auth = auth;
    this.settings = settings;
  }

  /**
   * Get current access token
   */
  get accessToken(): string {
    return this.auth.accessToken;
  }

  /**
   * Get current auth state
   */
  get currentAuth(): OpenAIOAuth {
    return this.auth;
  }

  /**
   * Ensure tokens are valid, refresh if needed
   */
  async ensureValidTokens(): Promise<void> {
    if (shouldRefreshTokens(this.auth.expiresAt, this.settings)) {
      const newTokens = await refreshTokens(this.auth.refreshToken, this.settings);
      this.auth.accessToken = newTokens.accessToken;
      this.auth.refreshToken = newTokens.refreshToken;
      this.auth.expiresAt = newTokens.expiresAt;
    }
  }

  /**
   * Build authorization headers
   */
  buildHeaders(): Record<string, string> {
    const accountId = extractAccountId(this.auth.accessToken);

    const headers: Record<string, string> = {
      'Authorization': `Bearer ${this.auth.accessToken}`,
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'openai-beta': 'responses=experimental',
      'openai-originator': 'codex_cli_rs',
    };

    if (accountId) {
      headers['chatgpt-account-id'] = accountId;
    }

    return headers;
  }
}
