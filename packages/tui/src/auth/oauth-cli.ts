/**
 * @fileoverview OAuth CLI Integration
 *
 * Provides OAuth authentication flow for the CLI.
 * Handles token storage, refresh, and login flow.
 */
import { randomBytes } from 'crypto';
import * as readline from 'readline';
import type { AnthropicAuth } from '@tron/agent';
import {
  getProviderAuth,
  saveProviderAuth,
  clearProviderAuth,
  type OAuthTokens,
  type ProviderAuth,
} from '@tron/agent';

// =============================================================================
// Configuration
// =============================================================================

// Using the official Claude Code CLI OAuth client ID
// This enables Claude Max/Pro subscription users to authenticate
const OAUTH_CONFIG = {
  clientId: '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
  authorizationEndpoint: 'https://claude.ai/oauth/authorize',
  tokenEndpoint: 'https://console.anthropic.com/v1/oauth/token',
  // Use Anthropic's code callback page - displays code for user to copy/paste
  // This avoids Cloudflare blocking issues with local callback servers
  redirectUri: 'https://console.anthropic.com/oauth/code/callback',
  scopes: 'org:create_api_key user:profile user:inference',
};

// =============================================================================
// Token Storage (using unified auth)
// =============================================================================

/**
 * Load stored Anthropic authentication from unified auth.json
 */
async function loadStoredAuth(): Promise<ProviderAuth | null> {
  return getProviderAuth('anthropic');
}

/**
 * Save OAuth tokens for Anthropic
 */
async function saveOAuthTokens(tokens: OAuthTokens): Promise<void> {
  const existing = await getProviderAuth('anthropic');
  await saveProviderAuth('anthropic', {
    ...existing,
    oauth: tokens,
  });
}

/**
 * Save API key for Anthropic
 */
async function saveApiKeyAuth(apiKey: string): Promise<void> {
  const existing = await getProviderAuth('anthropic');
  await saveProviderAuth('anthropic', {
    ...existing,
    apiKey,
  });
}

/**
 * Clear Anthropic authentication
 */
async function clearAuth(): Promise<void> {
  await clearProviderAuth('anthropic');
}

// =============================================================================
// OAuth Flow
// =============================================================================

/**
 * Base64url encode bytes
 */
function base64urlEncode(buffer: Buffer): string {
  return buffer.toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
}

/**
 * Generate PKCE challenge with SHA-256
 */
async function generatePkce(): Promise<{ codeVerifier: string; codeChallenge: string }> {
  const codeVerifier = base64urlEncode(randomBytes(32));

  // Compute SHA-256 hash for code_challenge
  const { createHash } = await import('crypto');
  const hash = createHash('sha256').update(codeVerifier).digest();
  const codeChallenge = base64urlEncode(hash);

  return { codeVerifier, codeChallenge };
}

/**
 * Prompt user to paste the authorization code from the browser
 */
function promptForAuthCode(): Promise<string> {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    rl.question('\nPaste the authorization code: ', (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

/**
 * Exchange authorization code for tokens
 * The authCode from the browser is in format: code#state
 */
async function exchangeCodeForTokens(
  authCode: string,
  codeVerifier: string
): Promise<OAuthTokens> {
  // Parse the auth code - format is "code#state"
  const splits = authCode.split('#');
  const code = splits[0];
  const state = splits[1];

  if (!code) {
    throw new Error('Invalid authorization code format. Expected format: code#state');
  }

  const response = await fetch(OAUTH_CONFIG.tokenEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      grant_type: 'authorization_code',
      client_id: OAUTH_CONFIG.clientId,
      code,
      state,
      redirect_uri: OAUTH_CONFIG.redirectUri,
      code_verifier: codeVerifier,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Token exchange failed: ${error}`);
  }

  const data = await response.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  // Store the actual expiry time (buffer applied only when checking)
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt: Date.now() + data.expires_in * 1000,
  };
}

/**
 * Refresh access token
 */
async function refreshTokens(refreshToken: string): Promise<OAuthTokens> {
  const response = await fetch(OAUTH_CONFIG.tokenEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      client_id: OAUTH_CONFIG.clientId,
      refresh_token: refreshToken,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Token refresh failed: ${error}`);
  }

  const data = await response.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  // Store the actual expiry time (buffer applied only when checking)
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt: Date.now() + data.expires_in * 1000,
  };
}

// =============================================================================
// Public API
// =============================================================================

/**
 * Get authentication for the CLI
 * Returns stored auth if valid, or null if login is needed
 *
 * IMPORTANT: This function does NOT check ANTHROPIC_API_KEY environment variable.
 * This is intentional - when using Claude Max subscription, you MUST unset
 * ANTHROPIC_API_KEY to prevent it from being used instead of OAuth tokens.
 *
 * Priority:
 * 1. OAuth tokens from ~/.tron/auth.json providers.anthropic (refreshed if needed)
 * 2. API key from ~/.tron/auth.json providers.anthropic
 * 3. null if no auth configured
 */
export async function getAuth(): Promise<AnthropicAuth | null> {
  // Load stored auth from unified auth.json
  const stored = await loadStoredAuth();
  if (!stored) {
    return null;
  }

  // OAuth tokens take precedence (for Claude Max users)
  if (stored.oauth) {
    // Check if access token is expired (with 5 min buffer)
    if (stored.oauth.expiresAt - 5 * 60 * 1000 < Date.now()) {
      try {
        // Try to refresh
        const newTokens = await refreshTokens(stored.oauth.refreshToken);
        await saveOAuthTokens(newTokens);
        return {
          type: 'oauth',
          accessToken: newTokens.accessToken,
          refreshToken: newTokens.refreshToken,
          expiresAt: newTokens.expiresAt,
        };
      } catch {
        // Refresh failed, need to login again
        return null;
      }
    }

    return {
      type: 'oauth',
      accessToken: stored.oauth.accessToken,
      refreshToken: stored.oauth.refreshToken,
      expiresAt: stored.oauth.expiresAt,
    };
  }

  // Fallback to API key in auth.json
  if (stored.apiKey) {
    return { type: 'api_key', apiKey: stored.apiKey };
  }

  return null;
}

/**
 * Start OAuth login flow
 * Opens browser for user to authenticate, then prompts for code paste
 */
export async function login(): Promise<AnthropicAuth> {
  const { codeVerifier, codeChallenge } = await generatePkce();

  // Build authorization URL
  // Note: state is set to codeVerifier as per the working implementation
  const authParams = new URLSearchParams({
    code: 'true',
    client_id: OAUTH_CONFIG.clientId,
    response_type: 'code',
    redirect_uri: OAUTH_CONFIG.redirectUri,
    scope: OAUTH_CONFIG.scopes,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    state: codeVerifier,
  });

  const authUrl = `${OAUTH_CONFIG.authorizationEndpoint}?${authParams.toString()}`;

  // Open browser
  console.log('\n🔐 Opening browser for authentication...');
  console.log(`\nIf browser doesn't open, visit:\n${authUrl}\n`);

  // Try to open browser (platform-specific)
  const { exec } = await import('child_process');
  const platform = process.platform;
  const openCommand =
    platform === 'darwin' ? 'open' :
    platform === 'win32' ? 'start' : 'xdg-open';

  exec(`${openCommand} "${authUrl}"`);

  // Prompt user to paste the authorization code from the browser
  const authCode = await promptForAuthCode();

  if (!authCode) {
    throw new Error('No authorization code provided');
  }

  // Exchange code for tokens
  console.log('\nExchanging authorization code...');
  const tokens = await exchangeCodeForTokens(authCode, codeVerifier);

  // Save tokens to unified auth
  await saveOAuthTokens(tokens);

  console.log('Authentication successful!\n');

  return {
    type: 'oauth',
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresAt: tokens.expiresAt,
  };
}

/**
 * Set API key directly (for users without Claude Max)
 */
export async function setApiKey(apiKey: string): Promise<void> {
  await saveApiKeyAuth(apiKey);
}

/**
 * Logout and clear stored auth
 */
export async function logout(silent = false): Promise<void> {
  await clearAuth();
  if (!silent) {
    console.log('Logged out successfully\n');
  }
}

/**
 * Check if user is authenticated
 */
export async function isAuthenticated(): Promise<boolean> {
  const auth = await getAuth();
  return auth !== null;
}
