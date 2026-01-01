/**
 * @fileoverview OAuth CLI Integration
 *
 * Provides OAuth authentication flow for the CLI.
 * Handles token storage, refresh, and login flow.
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import * as http from 'http';
import { URL } from 'url';
import { randomBytes } from 'crypto';
import type { AnthropicAuth } from '@tron/core';

// =============================================================================
// Types
// =============================================================================

interface OAuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

interface StoredAuth {
  tokens?: OAuthTokens;
  apiKey?: string;
  lastUpdated: string;
}

// =============================================================================
// Configuration
// =============================================================================

const OAUTH_CONFIG = {
  clientId: 'tron-cli',
  authorizationEndpoint: 'https://console.anthropic.com/oauth/authorize',
  tokenEndpoint: 'https://console.anthropic.com/oauth/token',
  redirectUri: 'http://localhost:8976/callback',
  scopes: ['chat'],
};

const AUTH_FILE_PATH = path.join(os.homedir(), '.tron', 'auth.json');

// =============================================================================
// Token Storage
// =============================================================================

/**
 * Load stored authentication
 */
async function loadStoredAuth(): Promise<StoredAuth | null> {
  try {
    const data = await fs.readFile(AUTH_FILE_PATH, 'utf-8');
    return JSON.parse(data) as StoredAuth;
  } catch {
    return null;
  }
}

/**
 * Save authentication to disk
 */
async function saveAuth(auth: StoredAuth): Promise<void> {
  const dir = path.dirname(AUTH_FILE_PATH);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(AUTH_FILE_PATH, JSON.stringify(auth, null, 2), {
    mode: 0o600, // Owner read/write only
  });
}

/**
 * Clear stored authentication
 */
async function clearAuth(): Promise<void> {
  try {
    await fs.unlink(AUTH_FILE_PATH);
  } catch {
    // Ignore if file doesn't exist
  }
}

// =============================================================================
// OAuth Flow
// =============================================================================

/**
 * Generate PKCE challenge
 */
function generatePkce(): { codeVerifier: string; codeChallenge: string } {
  const codeVerifier = randomBytes(32).toString('base64url');
  // In a real implementation, we'd compute SHA256 hash
  // For simplicity, using plain method here
  const codeChallenge = codeVerifier;
  return { codeVerifier, codeChallenge };
}

/**
 * Start local server to receive OAuth callback
 */
function startCallbackServer(
  state: string,
  _codeVerifier: string
): Promise<{ code: string; server: http.Server }> {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      if (!req.url?.startsWith('/callback')) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }

      const url = new URL(req.url, 'http://localhost');
      const code = url.searchParams.get('code');
      const returnedState = url.searchParams.get('state');
      const error = url.searchParams.get('error');

      if (error) {
        res.writeHead(400);
        res.end(`Authentication error: ${error}`);
        reject(new Error(`OAuth error: ${error}`));
        return;
      }

      if (returnedState !== state) {
        res.writeHead(400);
        res.end('Invalid state parameter');
        reject(new Error('Invalid OAuth state'));
        return;
      }

      if (!code) {
        res.writeHead(400);
        res.end('Missing authorization code');
        reject(new Error('Missing authorization code'));
        return;
      }

      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`
        <html>
          <body style="font-family: system-ui; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0;">
            <div style="text-align: center;">
              <h1>✅ Authentication Successful</h1>
              <p>You can close this window and return to the terminal.</p>
            </div>
          </body>
        </html>
      `);

      resolve({ code, server });
    });

    server.listen(8976, 'localhost', () => {
      // Server started
    });

    server.on('error', reject);

    // Timeout after 5 minutes
    setTimeout(() => {
      server.close();
      reject(new Error('OAuth callback timeout'));
    }, 5 * 60 * 1000);
  });
}

/**
 * Exchange authorization code for tokens
 */
async function exchangeCodeForTokens(
  code: string,
  codeVerifier: string
): Promise<OAuthTokens> {
  const response = await fetch(OAUTH_CONFIG.tokenEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: OAUTH_CONFIG.clientId,
      code,
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
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
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
 */
export async function getAuth(): Promise<AnthropicAuth | null> {
  // First, check for API key in environment
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (apiKey) {
    return { type: 'api_key', apiKey };
  }

  // Then check stored auth
  const stored = await loadStoredAuth();
  if (!stored) {
    return null;
  }

  // API key takes precedence
  if (stored.apiKey) {
    return { type: 'api_key', apiKey: stored.apiKey };
  }

  // Check OAuth tokens
  if (stored.tokens) {
    // Check if access token is expired (with 5 min buffer)
    if (stored.tokens.expiresAt - 5 * 60 * 1000 < Date.now()) {
      try {
        // Try to refresh
        const newTokens = await refreshTokens(stored.tokens.refreshToken);
        await saveAuth({
          tokens: newTokens,
          lastUpdated: new Date().toISOString(),
        });
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
      accessToken: stored.tokens.accessToken,
      refreshToken: stored.tokens.refreshToken,
      expiresAt: stored.tokens.expiresAt,
    };
  }

  return null;
}

/**
 * Start OAuth login flow
 * Opens browser and waits for callback
 */
export async function login(): Promise<AnthropicAuth> {
  const state = randomBytes(16).toString('hex');
  const { codeVerifier, codeChallenge } = generatePkce();

  // Build authorization URL
  const authUrl = new URL(OAUTH_CONFIG.authorizationEndpoint);
  authUrl.searchParams.set('client_id', OAUTH_CONFIG.clientId);
  authUrl.searchParams.set('redirect_uri', OAUTH_CONFIG.redirectUri);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', OAUTH_CONFIG.scopes.join(' '));
  authUrl.searchParams.set('state', state);
  authUrl.searchParams.set('code_challenge', codeChallenge);
  authUrl.searchParams.set('code_challenge_method', 'plain');

  // Start callback server first
  const callbackPromise = startCallbackServer(state, codeVerifier);

  // Open browser
  console.log('\n🔐 Opening browser for authentication...');
  console.log(`\nIf browser doesn't open, visit:\n${authUrl.toString()}\n`);

  // Try to open browser (platform-specific)
  const { exec } = await import('child_process');
  const platform = process.platform;
  const openCommand =
    platform === 'darwin' ? 'open' :
    platform === 'win32' ? 'start' : 'xdg-open';

  exec(`${openCommand} "${authUrl.toString()}"`);

  // Wait for callback
  const { code, server } = await callbackPromise;
  server.close();

  // Exchange code for tokens
  console.log('Exchanging authorization code...');
  const tokens = await exchangeCodeForTokens(code, codeVerifier);

  // Save tokens
  await saveAuth({
    tokens,
    lastUpdated: new Date().toISOString(),
  });

  console.log('✅ Authentication successful!\n');

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
  await saveAuth({
    apiKey,
    lastUpdated: new Date().toISOString(),
  });
}

/**
 * Logout and clear stored auth
 */
export async function logout(): Promise<void> {
  await clearAuth();
  console.log('✅ Logged out successfully\n');
}

/**
 * Check if user is authenticated
 */
export async function isAuthenticated(): Promise<boolean> {
  const auth = await getAuth();
  return auth !== null;
}
