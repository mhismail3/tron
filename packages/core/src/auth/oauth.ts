/**
 * @fileoverview OAuth authentication for Claude Max/Pro subscriptions
 *
 * Implements PKCE (Proof Key for Code Exchange) flow for secure OAuth
 * without requiring a client secret.
 */

import crypto from 'crypto';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('oauth');

// Get OAuth settings (loaded lazily on first access)
function getOAuthSettings() {
  return getSettings().api.anthropic;
}

// =============================================================================
// Types
// =============================================================================

/**
 * OAuth tokens returned after authentication
 */
export interface OAuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

/**
 * PKCE challenge/verifier pair
 */
export interface PKCEPair {
  verifier: string;
  challenge: string;
}

/**
 * OAuth error response
 */
export class OAuthError extends Error {
  constructor(
    message: string,
    public code: string,
    public statusCode?: number
  ) {
    super(message);
    this.name = 'OAuthError';
  }
}

// =============================================================================
// Settings Accessors
// =============================================================================

/** Get Anthropic auth URL from settings */
function getAuthUrl(): string {
  return getOAuthSettings().authUrl;
}

/** Get Anthropic token URL from settings */
function getTokenUrl(): string {
  return getOAuthSettings().tokenUrl;
}

/** Get OAuth client ID from settings (env var takes precedence) */
function getClientId(): string {
  return process.env.ANTHROPIC_CLIENT_ID ?? getOAuthSettings().clientId;
}

/** Get OAuth scopes from settings */
function getScopes(): string[] {
  return getOAuthSettings().scopes;
}

/** Get token expiry buffer from settings */
function getExpiryBuffer(): number {
  return getOAuthSettings().tokenExpiryBufferSeconds;
}

// =============================================================================
// PKCE Functions
// =============================================================================

/**
 * Generate a cryptographically secure PKCE verifier and challenge
 *
 * The verifier is a random string, and the challenge is its SHA256 hash
 * encoded as base64url (no padding).
 */
export function generatePKCE(): PKCEPair {
  // Generate 32 bytes of random data for the verifier
  const randomBytes = crypto.randomBytes(32);
  const verifier = randomBytes.toString('base64url');

  // Create SHA256 hash of verifier
  const hash = crypto.createHash('sha256').update(verifier).digest();
  const challenge = hash.toString('base64url');

  logger.debug('Generated PKCE pair', {
    verifierLength: verifier.length,
    challengeLength: challenge.length,
  });

  return { verifier, challenge };
}

// =============================================================================
// Authorization URL
// =============================================================================

/**
 * Construct the authorization URL for the OAuth flow
 *
 * @param challenge - PKCE challenge (from generatePKCE)
 * @returns Full authorization URL to open in browser
 */
export function getAuthorizationUrl(challenge: string): string {
  const clientId = getClientId();
  const scopes = getScopes();
  const authUrl = getAuthUrl();

  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: 'urn:ietf:wg:oauth:2.0:oob', // OOB for CLI apps
    response_type: 'code',
    scope: scopes.join(' '),
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });

  const url = `${authUrl}?${params.toString()}`;

  logger.debug('Generated authorization URL', {
    clientId,
    scopes,
  });

  return url;
}

// =============================================================================
// Token Exchange
// =============================================================================

/**
 * Exchange an authorization code for access and refresh tokens
 *
 * @param code - Authorization code from OAuth redirect
 * @param verifier - PKCE verifier (from generatePKCE)
 * @returns OAuth tokens
 * @throws OAuthError if exchange fails
 */
export async function exchangeCodeForTokens(
  code: string,
  verifier: string
): Promise<OAuthTokens> {
  logger.info('Exchanging authorization code for tokens');

  const clientId = getClientId();
  const tokenUrl = getTokenUrl();
  const expiryBuffer = getExpiryBuffer();

  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    code_verifier: verifier,
    client_id: clientId,
  });

  const response = await fetch(tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    const errorCode = (errorData as { error?: string }).error ?? 'unknown_error';
    logger.error('Token exchange failed', {
      status: response.status,
      error: errorCode,
    });
    throw new OAuthError(
      `Token exchange failed: ${errorCode}`,
      errorCode,
      response.status
    );
  }

  const data = await response.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  // Calculate expiry with buffer (refresh before actual expiry)
  const expiresAt = Date.now() + (data.expires_in - expiryBuffer) * 1000;

  logger.info('Token exchange successful', {
    expiresIn: data.expires_in,
    expiresAt: new Date(expiresAt).toISOString(),
  });

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt,
  };
}

// =============================================================================
// Token Refresh
// =============================================================================

/**
 * Refresh an expired access token using a refresh token
 *
 * @param refreshToken - Valid refresh token
 * @returns New OAuth tokens (both access and refresh are rotated)
 * @throws OAuthError if refresh fails
 */
export async function refreshOAuthToken(refreshToken: string): Promise<OAuthTokens> {
  logger.info('Refreshing OAuth token');

  const clientId = getClientId();
  const tokenUrl = getTokenUrl();
  const expiryBuffer = getExpiryBuffer();

  const body = new URLSearchParams({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    client_id: clientId,
  });

  const response = await fetch(tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    const errorCode = (errorData as { error?: string }).error ?? 'unknown_error';
    logger.error('Token refresh failed', {
      status: response.status,
      error: errorCode,
    });
    throw new OAuthError(
      `Token refresh failed: ${errorCode}`,
      errorCode,
      response.status
    );
  }

  const data = await response.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  const expiresAt = Date.now() + (data.expires_in - expiryBuffer) * 1000;

  logger.info('Token refresh successful', {
    expiresIn: data.expires_in,
    expiresAt: new Date(expiresAt).toISOString(),
  });

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt,
  };
}

// =============================================================================
// Token Validation
// =============================================================================

/**
 * Check if tokens need refresh
 *
 * @param tokens - Current OAuth tokens
 * @returns true if tokens should be refreshed
 */
export function shouldRefreshTokens(tokens: OAuthTokens): boolean {
  return Date.now() >= tokens.expiresAt;
}

/**
 * Check if access token is an OAuth token (vs API key)
 *
 * @param token - Token to check
 * @returns true if token appears to be an OAuth access token
 */
export function isOAuthToken(token: string): boolean {
  return token.startsWith('sk-ant-oat');
}
