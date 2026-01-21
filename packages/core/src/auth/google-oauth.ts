/**
 * @fileoverview Google OAuth authentication for Gemini models
 *
 * Implements OAuth 2.0 with PKCE flow for Google Cloud Code Assist API access.
 * Supports two authentication backends:
 * 1. Cloud Code Assist (production): cloudcode-pa.googleapis.com
 * 2. Antigravity (sandbox/free tier): daily-cloudcode-pa.sandbox.googleapis.com
 *
 * Based on Gemini CLI and Pi Coding Agent OAuth patterns.
 */

import crypto from 'crypto';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';
import { loadAuthStorage, saveProviderOAuthTokens, getProviderAuth } from './unified.js';
import type { OAuthTokens } from './types.js';

const logger = createLogger('google-oauth');

// =============================================================================
// Types
// =============================================================================

/**
 * Google OAuth endpoint type
 */
export type GoogleOAuthEndpoint = 'cloud-code-assist' | 'antigravity';

/**
 * Google OAuth configuration from settings
 */
export interface GoogleOAuthConfig {
  authUrl: string;
  tokenUrl: string;
  clientId: string;
  clientSecret?: string;
  scopes: string[];
  redirectUri: string;
  tokenExpiryBufferSeconds: number;
  /** API endpoint for Gemini requests */
  apiEndpoint: string;
  /** API version path */
  apiVersion: string;
}

/**
 * PKCE challenge/verifier pair
 */
export interface GooglePKCEPair {
  verifier: string;
  challenge: string;
}

/**
 * OAuth error response
 */
export class GoogleOAuthError extends Error {
  constructor(
    message: string,
    public code: string,
    public statusCode?: number
  ) {
    super(message);
    this.name = 'GoogleOAuthError';
  }
}

// =============================================================================
// Constants - OAuth Credentials
// =============================================================================

/**
 * Cloud Code Assist OAuth credentials (used by Gemini CLI)
 * These are public OAuth client credentials for device authorization flow.
 */
export const CLOUD_CODE_ASSIST_CONFIG: GoogleOAuthConfig = {
  authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenUrl: 'https://oauth2.googleapis.com/token',
  // Gemini CLI OAuth client
  clientId: '',
  clientSecret: '',
  scopes: [
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/userinfo.email',
    'openid',
  ],
  redirectUri: 'http://localhost:45289',
  tokenExpiryBufferSeconds: 300,
  apiEndpoint: 'https://cloudcode-pa.googleapis.com',
  apiVersion: 'v1internal',
};

/**
 * Antigravity (sandbox) OAuth credentials
 * Provides free tier access to Gemini 3 models.
 *
 * Note: Antigravity uses a DIFFERENT OAuth client ID than Gemini CLI!
 * This client ID is from the Antigravity IDE and grants access to the
 * daily-cloudcode-pa.sandbox endpoint.
 */
export const ANTIGRAVITY_CONFIG: GoogleOAuthConfig = {
  authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenUrl: 'https://oauth2.googleapis.com/token',
  // Antigravity-specific OAuth client (different from Gemini CLI!)
  clientId: '',
  // Antigravity client secret (from antigravity-auth project)
  clientSecret: '',
  scopes: [
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'https://www.googleapis.com/auth/cclog',
    'https://www.googleapis.com/auth/experimentsandconfigs',
    'openid',
  ],
  redirectUri: 'http://localhost:51121/oauth-callback',
  tokenExpiryBufferSeconds: 300,
  // Sandbox endpoint for free tier
  apiEndpoint: 'https://daily-cloudcode-pa.sandbox.googleapis.com',
  apiVersion: 'v1internal',
};

// =============================================================================
// Settings Accessors
// =============================================================================

/**
 * Get Google OAuth settings from Tron settings
 * Falls back to Cloud Code Assist defaults if not configured.
 */
function getGoogleOAuthSettings(): GoogleOAuthConfig {
  const settings = getSettings();
  const googleSettings = settings.api.google;

  if (!googleSettings) {
    // Default to Cloud Code Assist config
    return CLOUD_CODE_ASSIST_CONFIG;
  }

  return {
    authUrl: googleSettings.authUrl ?? CLOUD_CODE_ASSIST_CONFIG.authUrl,
    tokenUrl: googleSettings.tokenUrl ?? CLOUD_CODE_ASSIST_CONFIG.tokenUrl,
    clientId: googleSettings.clientId ?? CLOUD_CODE_ASSIST_CONFIG.clientId,
    clientSecret: googleSettings.clientSecret ?? CLOUD_CODE_ASSIST_CONFIG.clientSecret,
    scopes: googleSettings.scopes ?? CLOUD_CODE_ASSIST_CONFIG.scopes,
    redirectUri: googleSettings.redirectUri ?? CLOUD_CODE_ASSIST_CONFIG.redirectUri,
    tokenExpiryBufferSeconds: googleSettings.tokenExpiryBufferSeconds ?? CLOUD_CODE_ASSIST_CONFIG.tokenExpiryBufferSeconds,
    apiEndpoint: googleSettings.apiEndpoint ?? CLOUD_CODE_ASSIST_CONFIG.apiEndpoint,
    apiVersion: googleSettings.apiVersion ?? CLOUD_CODE_ASSIST_CONFIG.apiVersion,
  };
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
export function generateGooglePKCE(): GooglePKCEPair {
  // Generate 32 bytes of random data for the verifier
  const randomBytes = crypto.randomBytes(32);
  const verifier = randomBytes.toString('base64url');

  // Create SHA256 hash of verifier
  const hash = crypto.createHash('sha256').update(verifier).digest();
  const challenge = hash.toString('base64url');

  logger.debug('Generated Google PKCE pair', {
    verifierLength: verifier.length,
    challengeLength: challenge.length,
  });

  return { verifier, challenge };
}

// =============================================================================
// Authorization URL
// =============================================================================

/**
 * Construct the authorization URL for the Google OAuth flow
 *
 * @param challenge - PKCE challenge (from generateGooglePKCE)
 * @param endpoint - Which endpoint to use (cloud-code-assist or antigravity)
 * @returns Full authorization URL to open in browser
 */
export function getGoogleAuthorizationUrl(
  challenge: string,
  endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'
): string {
  const config = endpoint === 'antigravity' ? ANTIGRAVITY_CONFIG : getGoogleOAuthSettings();

  const params = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    response_type: 'code',
    scope: config.scopes.join(' '),
    code_challenge: challenge,
    code_challenge_method: 'S256',
    access_type: 'offline', // Request refresh token
    prompt: 'consent', // Force consent to get refresh token
    state: challenge, // Use challenge as state for verification
  });

  const url = `${config.authUrl}?${params.toString()}`;

  logger.debug('Generated Google authorization URL', {
    endpoint,
    clientId: config.clientId,
    scopes: config.scopes,
    redirectUri: config.redirectUri,
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
 * @param verifier - PKCE verifier (from generateGooglePKCE)
 * @param endpoint - Which endpoint was used for authorization
 * @returns OAuth tokens
 * @throws GoogleOAuthError if exchange fails
 */
export async function exchangeGoogleCodeForTokens(
  code: string,
  verifier: string,
  endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'
): Promise<OAuthTokens> {
  logger.info('Exchanging Google authorization code for tokens', { endpoint });

  const config = endpoint === 'antigravity' ? ANTIGRAVITY_CONFIG : getGoogleOAuthSettings();

  const body: Record<string, string> = {
    grant_type: 'authorization_code',
    client_id: config.clientId,
    code,
    redirect_uri: config.redirectUri,
    code_verifier: verifier,
  };

  // Add client secret - required even for public clients (can be empty string)
  // Google's OAuth still requires the parameter to be present
  body.client_secret = config.clientSecret ?? '';

  const response = await fetch(config.tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(body).toString(),
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    const errorCode = (errorData as { error?: string }).error ?? 'unknown_error';
    const errorDesc = (errorData as { error_description?: string }).error_description ?? '';
    logger.error('Google token exchange failed', {
      status: response.status,
      error: errorCode,
      description: errorDesc,
    });
    throw new GoogleOAuthError(
      `Token exchange failed: ${errorCode} - ${errorDesc}`,
      errorCode,
      response.status
    );
  }

  const data = (await response.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in: number;
    token_type: string;
  };

  // Calculate expiry with buffer (refresh before actual expiry)
  const expiresAt = Date.now() + (data.expires_in - config.tokenExpiryBufferSeconds) * 1000;

  logger.info('Google token exchange successful', {
    expiresIn: data.expires_in,
    expiresAt: new Date(expiresAt).toISOString(),
    hasRefreshToken: !!data.refresh_token,
  });

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? '',
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
 * @param endpoint - Which endpoint was used for original authorization
 * @returns New OAuth tokens
 * @throws GoogleOAuthError if refresh fails
 */
export async function refreshGoogleOAuthToken(
  refreshToken: string,
  endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'
): Promise<OAuthTokens> {
  logger.info('Refreshing Google OAuth token', { endpoint });

  const config = endpoint === 'antigravity' ? ANTIGRAVITY_CONFIG : getGoogleOAuthSettings();

  const body: Record<string, string> = {
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    client_id: config.clientId,
  };

  // Add client secret - required even for public clients (can be empty string)
  body.client_secret = config.clientSecret ?? '';

  const response = await fetch(config.tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(body).toString(),
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    const errorCode = (errorData as { error?: string }).error ?? 'unknown_error';
    const errorDesc = (errorData as { error_description?: string }).error_description ?? '';
    logger.error('Google token refresh failed', {
      status: response.status,
      error: errorCode,
      description: errorDesc,
    });
    throw new GoogleOAuthError(
      `Token refresh failed: ${errorCode} - ${errorDesc}`,
      errorCode,
      response.status
    );
  }

  const data = (await response.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in: number;
  };

  const expiresAt = Date.now() + (data.expires_in - config.tokenExpiryBufferSeconds) * 1000;

  logger.info('Google token refresh successful', {
    expiresIn: data.expires_in,
    expiresAt: new Date(expiresAt).toISOString(),
  });

  return {
    accessToken: data.access_token,
    // Google may or may not return a new refresh token
    refreshToken: data.refresh_token ?? refreshToken,
    expiresAt,
  };
}

// =============================================================================
// Token Validation
// =============================================================================

/**
 * Check if Google tokens need refresh
 *
 * @param tokens - Current OAuth tokens
 * @returns true if tokens should be refreshed
 */
export function shouldRefreshGoogleTokens(tokens: OAuthTokens): boolean {
  return Date.now() >= tokens.expiresAt;
}

/**
 * Check if token appears to be a Google OAuth token
 *
 * @param token - Token to check
 * @returns true if token appears to be a Google access token
 */
export function isGoogleOAuthToken(token: string): boolean {
  // Google access tokens typically start with 'ya29.' or are JWT format
  return token.startsWith('ya29.') || (token.includes('.') && token.split('.').length === 3);
}

// =============================================================================
// Server-side Auth Loading
// =============================================================================

/**
 * Google-specific auth structure for runtime use
 */
export interface GoogleAuth {
  type: 'oauth' | 'api_key';
  accessToken?: string;
  refreshToken?: string;
  expiresAt?: number;
  apiKey?: string;
  /** Which OAuth endpoint was used */
  endpoint?: GoogleOAuthEndpoint;
  /** API endpoint URL for requests */
  apiEndpoint?: string;
  /** API version path */
  apiVersion?: string;
  /** Project ID for x-goog-user-project header (required for Cloud Code Assist) */
  projectId?: string;
}

// =============================================================================
// Project Discovery (loadCodeAssist)
// =============================================================================

/**
 * Default headers for Google API requests
 */
const GOOGLE_API_HEADERS = {
  'Content-Type': 'application/json',
  'User-Agent': 'tron-ai-agent/1.0.0',
  'X-Goog-Api-Client': 'gl-node/22.0.0',
};

/**
 * Default project ID for Antigravity (free tier fallback)
 * This is the project used by Gemini CLI for free tier access
 */
const ANTIGRAVITY_DEFAULT_PROJECT = 'rising-fact-p41fc';

/**
 * Response from loadCodeAssist API
 */
interface LoadCodeAssistResponse {
  cloudaicompanionProject?: string | { id?: string };
  managedProject?: string | { id?: string };
  tier?: string;
}

/**
 * Discover the project ID by calling loadCodeAssist API
 *
 * This is REQUIRED for OAuth authentication with Cloud Code Assist.
 * The API returns the user's assigned project ID which must be included
 * in subsequent requests via the x-goog-user-project header.
 *
 * @param accessToken - OAuth access token
 * @param endpoint - Which endpoint to use
 * @returns Project ID or null if discovery fails
 */
export async function discoverGoogleProject(
  accessToken: string,
  endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'
): Promise<string | null> {
  const config = endpoint === 'antigravity' ? ANTIGRAVITY_CONFIG : CLOUD_CODE_ASSIST_CONFIG;

  // Check for environment variable override
  const envProjectId = process.env.GOOGLE_CLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT_ID;

  logger.info('Discovering Google project for Code Assist', {
    endpoint,
    hasEnvProject: !!envProjectId,
  });

  try {
    const url = `${config.apiEndpoint}/${config.apiVersion}:loadCodeAssist`;

    const headers: Record<string, string> = {
      ...GOOGLE_API_HEADERS,
      'Authorization': `Bearer ${accessToken}`,
    };

    const body = {
      cloudaicompanionProject: envProjectId,
      metadata: {
        ideType: 'IDE_UNSPECIFIED',
        platform: 'PLATFORM_UNSPECIFIED',
        pluginType: 'GEMINI',
        duetProject: envProjectId,
      },
    };

    logger.debug('Calling loadCodeAssist', { url });

    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const errorText = await response.text();
      logger.warn('loadCodeAssist failed', {
        status: response.status,
        error: errorText.slice(0, 200),
      });

      // For antigravity, use default project on failure
      if (endpoint === 'antigravity') {
        logger.info('Using default Antigravity project', { projectId: ANTIGRAVITY_DEFAULT_PROJECT });
        return ANTIGRAVITY_DEFAULT_PROJECT;
      }

      return envProjectId || null;
    }

    const data = (await response.json()) as LoadCodeAssistResponse;
    logger.debug('loadCodeAssist response', { data });

    // Extract project ID from response
    let projectId: string | null = null;

    // Try cloudaicompanionProject first
    if (data.cloudaicompanionProject) {
      projectId = typeof data.cloudaicompanionProject === 'string'
        ? data.cloudaicompanionProject
        : data.cloudaicompanionProject.id ?? null;
    }

    // Fallback to managedProject
    if (!projectId && data.managedProject) {
      projectId = typeof data.managedProject === 'string'
        ? data.managedProject
        : data.managedProject.id ?? null;
    }

    // Fallback to env var
    if (!projectId) {
      projectId = envProjectId || null;
    }

    // For antigravity, use default if still no project
    if (!projectId && endpoint === 'antigravity') {
      projectId = ANTIGRAVITY_DEFAULT_PROJECT;
    }

    logger.info('Google project discovered', { projectId, tier: data.tier });
    return projectId;
  } catch (error) {
    logger.error('Failed to discover Google project', { error });

    // For antigravity, use default project on error
    if (endpoint === 'antigravity') {
      logger.info('Using default Antigravity project after error', { projectId: ANTIGRAVITY_DEFAULT_PROJECT });
      return ANTIGRAVITY_DEFAULT_PROJECT;
    }

    return envProjectId || null;
  }
}

/**
 * Load authentication for Google/Gemini provider
 *
 * IMPORTANT: OAuth ALWAYS takes priority over API key when both are available.
 * This ensures users with Cloud Code Assist or Antigravity access use that
 * instead of consuming their API quota.
 *
 * Priority:
 * 1. GOOGLE_OAUTH_TOKEN env var (pre-configured OAuth token)
 * 2. OAuth tokens from ~/.tron/auth.json providers.google (refreshed if needed)
 * 3. GOOGLE_API_KEY env var (fallback)
 * 4. API key from ~/.tron/auth.json providers.google (last resort)
 * 5. null if no auth configured
 *
 * @returns GoogleAuth if authenticated, null if login needed
 */
export async function loadGoogleServerAuth(): Promise<GoogleAuth | null> {
  const config = getGoogleOAuthSettings();

  // Priority 1: OAuth token from environment
  const envToken = process.env.GOOGLE_OAUTH_TOKEN;
  if (envToken) {
    logger.info('Using GOOGLE_OAUTH_TOKEN from environment');
    return {
      type: 'oauth',
      accessToken: envToken,
      refreshToken: '',
      expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000, // Assume 1 year validity
      apiEndpoint: config.apiEndpoint,
      apiVersion: config.apiVersion,
    };
  }

  // Load from unified auth.json
  const auth = await loadAuthStorage();
  const googleAuth = auth?.providers.google;

  // Priority 2: OAuth tokens from auth.json (ALWAYS preferred over API key)
  if (googleAuth?.oauth) {
    const tokens = googleAuth.oauth;
    const endpoint: GoogleOAuthEndpoint =
      (googleAuth as any).endpoint ?? 'cloud-code-assist';
    const storedProjectId = (googleAuth as any).projectId as string | undefined;

    // Check if tokens need refresh
    if (shouldRefreshGoogleTokens(tokens)) {
      logger.info('Google OAuth tokens expired, refreshing...');
      try {
        const newTokens = await refreshGoogleOAuthToken(tokens.refreshToken, endpoint);

        // Save refreshed tokens back to unified auth
        await saveProviderOAuthTokens('google', newTokens);

        // Discover project ID if not stored (will also refresh stored value)
        let projectId = storedProjectId;
        if (!projectId) {
          projectId = await discoverGoogleProject(newTokens.accessToken, endpoint) ?? undefined;
        }

        return {
          type: 'oauth',
          accessToken: newTokens.accessToken,
          refreshToken: newTokens.refreshToken,
          expiresAt: newTokens.expiresAt,
          endpoint,
          projectId,
          apiEndpoint: endpoint === 'antigravity'
            ? ANTIGRAVITY_CONFIG.apiEndpoint
            : config.apiEndpoint,
          apiVersion: endpoint === 'antigravity'
            ? ANTIGRAVITY_CONFIG.apiVersion
            : config.apiVersion,
        };
      } catch (error) {
        logger.error('Failed to refresh Google OAuth tokens', { error });
        // Tokens are expired and refresh failed - try API key fallback
      }
    } else {
      // Tokens are still valid
      // Discover project ID if not stored
      let projectId = storedProjectId;
      if (!projectId) {
        projectId = await discoverGoogleProject(tokens.accessToken, endpoint) ?? undefined;
        // Store the discovered project ID for future use
        if (projectId) {
          try {
            const { saveProviderAuth } = await import('./unified.js');
            await saveProviderAuth('google', {
              ...googleAuth,
              projectId,
            } as any);
          } catch (e) {
            logger.warn('Failed to save discovered project ID', { error: e });
          }
        }
      }

      return {
        type: 'oauth',
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
        endpoint,
        projectId,
        apiEndpoint: endpoint === 'antigravity'
          ? ANTIGRAVITY_CONFIG.apiEndpoint
          : config.apiEndpoint,
        apiVersion: endpoint === 'antigravity'
          ? ANTIGRAVITY_CONFIG.apiVersion
          : config.apiVersion,
      };
    }
  }

  // Priority 3: API key from environment (fallback only)
  const envApiKey = process.env.GOOGLE_API_KEY ?? process.env.GEMINI_API_KEY;
  if (envApiKey) {
    logger.info('Using GOOGLE_API_KEY from environment (fallback)');
    return {
      type: 'api_key',
      apiKey: envApiKey,
    };
  }

  // Priority 4: API key from auth.json (last resort)
  if (googleAuth?.apiKey) {
    logger.info('Using API key from auth.json (fallback)');
    return {
      type: 'api_key',
      apiKey: googleAuth.apiKey,
    };
  }

  logger.warn('No Google authentication configured');
  return null;
}

/**
 * Save Google OAuth tokens with endpoint metadata
 *
 * @param tokens - OAuth tokens to save
 * @param endpoint - Which endpoint was used
 */
export async function saveGoogleOAuthTokens(
  tokens: OAuthTokens,
  endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'
): Promise<void> {
  // Save tokens using unified auth
  await saveProviderOAuthTokens('google', tokens);

  // Also save endpoint metadata by updating the provider auth directly
  const existingAuth = await getProviderAuth('google');
  const { saveProviderAuth } = await import('./unified.js');
  await saveProviderAuth('google', {
    ...existingAuth,
    oauth: tokens,
    endpoint,
  } as any);

  logger.info('Saved Google OAuth tokens', { endpoint });
}

// =============================================================================
// API Endpoint Helpers
// =============================================================================

/**
 * Get the Gemini API URL for a given model and action
 *
 * OAuth endpoints (Cloud Code Assist / Antigravity) use internal path format:
 *   /v1internal:action (model is passed in request body, not URL)
 *
 * API key endpoints use standard Gemini API path:
 *   /v1beta/models/{model}:action
 *
 * @param model - Gemini model ID (ignored for OAuth - must be in request body)
 * @param action - API action (streamGenerateContent, countTokens, etc.)
 * @param auth - Google auth with endpoint info
 * @returns Full API URL
 */
export function getGeminiApiUrl(
  model: string,
  action: 'streamGenerateContent' | 'countTokens' | 'generateContent',
  auth: GoogleAuth
): string {
  if (auth.type === 'oauth' && auth.apiEndpoint && auth.apiVersion) {
    // OAuth (Cloud Code Assist) uses /:action path - model must be in request body
    const streamParam = action === 'streamGenerateContent' ? '?alt=sse' : '';
    return `${auth.apiEndpoint}/${auth.apiVersion}:${action}${streamParam}`;
  } else {
    // API key path: standard Gemini API with model in URL
    return `https://generativelanguage.googleapis.com/v1beta/models/${model}:${action}`;
  }
}

/**
 * Get headers for Gemini API request
 *
 * @param auth - Google auth
 * @returns Headers object
 */
export function getGeminiApiHeaders(auth: GoogleAuth): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  if (auth.type === 'oauth' && auth.accessToken) {
    headers['Authorization'] = `Bearer ${auth.accessToken}`;
  }

  return headers;
}
