/**
 * @fileoverview Google OAuth Token Management
 *
 * Handles OAuth token refresh and project ID discovery for Google Gemini.
 * Extracted from google-provider.ts for modularity and testability.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import {
  refreshGoogleOAuthToken,
  shouldRefreshGoogleTokens,
  discoverGoogleProject,
} from '@infrastructure/auth/google-oauth.js';
import { saveProviderOAuthTokens, saveProviderAuth, getProviderAuthSync } from '@infrastructure/auth/unified.js';
import type { GoogleOAuthAuth, GoogleProviderAuth } from './types.js';

const logger = createLogger('google-auth');

// =============================================================================
// Types
// =============================================================================

export interface TokenRefreshResult {
  auth: GoogleOAuthAuth;
  refreshed: boolean;
}

// =============================================================================
// Token Management
// =============================================================================

/**
 * Check if OAuth tokens need refresh (5-minute buffer)
 */
export function shouldRefreshTokens(auth: GoogleProviderAuth): boolean {
  if (auth.type !== 'oauth') return false;
  return shouldRefreshGoogleTokens({
    accessToken: auth.accessToken,
    refreshToken: auth.refreshToken,
    expiresAt: auth.expiresAt,
  });
}

/**
 * Refresh OAuth tokens if needed
 *
 * @returns Updated auth object with new tokens, or original if no refresh needed
 */
export async function ensureValidTokens(auth: GoogleOAuthAuth): Promise<TokenRefreshResult> {
  if (!shouldRefreshGoogleTokens({
    accessToken: auth.accessToken,
    refreshToken: auth.refreshToken,
    expiresAt: auth.expiresAt,
  })) {
    return { auth, refreshed: false };
  }

  logger.info('Refreshing Google OAuth tokens');

  const endpoint = auth.endpoint ?? 'cloud-code-assist';
  try {
    const projectId = auth.projectId; // Preserve existing projectId
    const newTokens = await refreshGoogleOAuthToken(auth.refreshToken, endpoint);

    // Build updated auth - PRESERVE projectId
    const updatedAuth: GoogleOAuthAuth = {
      type: 'oauth',
      accessToken: newTokens.accessToken,
      refreshToken: newTokens.refreshToken,
      expiresAt: newTokens.expiresAt,
      endpoint,
      projectId, // Keep the existing projectId
    };

    // Persist refreshed tokens
    await saveProviderOAuthTokens('google', newTokens);

    logger.info('Google OAuth tokens refreshed successfully');
    return { auth: updatedAuth, refreshed: true };
  } catch (error) {
    const structured = categorizeError(error, { endpoint, operation: 'refreshGoogleOAuthToken' });
    logger.error('Failed to refresh Google OAuth tokens', {
      code: structured.code,
      category: LogErrorCategory.PROVIDER_AUTH,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw new Error(`Failed to refresh Google OAuth tokens: ${structured.message}`);
  }
}

/**
 * Ensure we have a valid project ID for OAuth requests
 *
 * Calls the loadCodeAssist API to discover the user's project ID,
 * which is REQUIRED for the x-goog-user-project header.
 *
 * @returns Updated auth with projectId, or original if already present or discovery failed
 */
export async function ensureProjectId(auth: GoogleOAuthAuth): Promise<GoogleOAuthAuth> {
  if (auth.projectId) return auth; // Already have projectId

  const endpoint = auth.endpoint ?? 'cloud-code-assist';
  logger.info('Discovering Google project ID for OAuth', { endpoint });

  try {
    const projectId = await discoverGoogleProject(auth.accessToken, endpoint);

    if (projectId) {
      // Build updated auth with projectId
      const updatedAuth: GoogleOAuthAuth = {
        ...auth,
        projectId,
      };

      // Persist the discovered projectId
      const storedAuth = getProviderAuthSync('google');
      if (storedAuth) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        await saveProviderAuth('google', {
          ...storedAuth,
          projectId,
        } as any);
      }

      logger.info('Google project ID discovered and saved', {
        projectId: projectId.slice(0, 15) + '...',
      });
      return updatedAuth;
    } else {
      logger.warn('Could not discover Google project ID - requests may fail');
      return auth;
    }
  } catch (error) {
    const structured = categorizeError(error, { endpoint, operation: 'discoverGoogleProject' });
    logger.error('Failed to discover Google project ID', {
      code: structured.code,
      category: LogErrorCategory.PROVIDER_API,
      error: structured.message,
      retryable: structured.retryable,
    });
    // Don't throw - let the request proceed and potentially fail with a clearer error
    return auth;
  }
}

/**
 * Load auth metadata (endpoint, projectId) from stored auth if not in config
 */
export function loadAuthMetadata(auth: GoogleOAuthAuth): GoogleOAuthAuth {
  let endpoint = auth.endpoint;
  let projectId = auth.projectId;

  // If endpoint or projectId not in config, try to load from stored auth
  if (!endpoint || !projectId) {
    try {
      const storedAuth = getProviderAuthSync('google');
      if (!endpoint) {
        endpoint = (storedAuth as GoogleOAuthAuth | null)?.endpoint;
      }
      if (!projectId) {
        projectId = (storedAuth as GoogleOAuthAuth | null)?.projectId;
      }
      logger.debug('Loaded auth metadata from stored auth', { endpoint, projectId });
    } catch (e) {
      const structured = categorizeError(e, { operation: 'loadAuthMetadata' });
      logger.debug('Could not load auth metadata from stored auth', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
      });
    }
  }

  // Default to cloud-code-assist if still not set
  endpoint = endpoint ?? 'cloud-code-assist';

  return {
    ...auth,
    endpoint,
    projectId,
  };
}
