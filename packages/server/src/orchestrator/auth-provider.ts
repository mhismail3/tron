/**
 * @fileoverview Auth Provider
 *
 * Extracts authentication logic from EventStoreOrchestrator:
 * - Model-specific auth resolution
 * - Codex OAuth token loading
 * - Auth caching and refresh
 *
 * Phase 8 of orchestrator refactoring.
 */
import {
  createLogger,
  loadServerAuth,
  loadGoogleServerAuth,
  getProviderAuthSync,
  detectProviderFromModel,
  type ServerAuth,
  type GoogleAuth,
} from '@tron/core';

const logger = createLogger('auth-provider');

// =============================================================================
// Types
// =============================================================================

export interface AuthProviderConfig {
  /** Initial cached auth (from orchestrator initialization) */
  initialAuth?: ServerAuth | null;
}

// =============================================================================
// AuthProvider Class
// =============================================================================

export class AuthProvider {
  private cachedAuth: ServerAuth | null;

  constructor(config?: AuthProviderConfig) {
    this.cachedAuth = config?.initialAuth ?? null;
  }

  /**
   * Set cached auth (for initialization after async loadServerAuth)
   */
  setCachedAuth(auth: ServerAuth | null): void {
    this.cachedAuth = auth;
  }

  /**
   * Get cached auth
   */
  getCachedAuth(): ServerAuth | null {
    return this.cachedAuth;
  }

  /**
   * Load Codex OAuth tokens from unified auth storage
   */
  loadCodexTokens(): { accessToken: string; refreshToken: string; expiresAt: number } | null {
    try {
      const codexAuth = getProviderAuthSync('openai-codex');
      if (codexAuth?.oauth) {
        return {
          accessToken: codexAuth.oauth.accessToken,
          refreshToken: codexAuth.oauth.refreshToken,
          expiresAt: codexAuth.oauth.expiresAt,
        };
      }
    } catch (error) {
      logger.warn('Failed to load Codex tokens', { error });
    }
    return null;
  }

  /**
   * Get authentication credentials for a given model.
   * Handles Codex OAuth tokens separately from standard auth.
   * Refreshes cached auth if OAuth tokens are expired.
   * Returns GoogleAuth for Google models (includes endpoint and projectId).
   */
  async getAuthForProvider(model: string): Promise<ServerAuth | GoogleAuth> {
    const providerType = detectProviderFromModel(model);

    if (providerType === 'openai-codex') {
      // Load Codex-specific OAuth tokens
      const codexTokens = this.loadCodexTokens();
      if (!codexTokens) {
        throw new Error('OpenAI Codex not authenticated. Sign in via the iOS app or use a different model.');
      }
      return {
        type: 'oauth',
        accessToken: codexTokens.accessToken,
        refreshToken: codexTokens.refreshToken,
        expiresAt: codexTokens.expiresAt,
      };
    }

    if (providerType === 'google') {
      // Load Google-specific auth (OAuth or API key)
      const googleAuth = await loadGoogleServerAuth();
      if (!googleAuth) {
        throw new Error('Google not authenticated. Run `tron login --provider google` or set GOOGLE_API_KEY.');
      }
      logger.info('Loaded Google auth', {
        type: googleAuth.type,
        endpoint: googleAuth.endpoint ?? 'standard',
        hasProjectId: !!googleAuth.projectId,
      });
      return googleAuth;
    }

    // Use cached auth from ~/.tron/auth.json (supports Claude Max OAuth)
    // Refresh cache if needed (OAuth tokens expire)
    if (!this.cachedAuth || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
      this.cachedAuth = await loadServerAuth();
    }

    if (!this.cachedAuth) {
      throw new Error('No authentication configured. Run `tron login` to authenticate.');
    }

    return this.cachedAuth;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createAuthProvider(config?: AuthProviderConfig): AuthProvider {
  return new AuthProvider(config);
}
