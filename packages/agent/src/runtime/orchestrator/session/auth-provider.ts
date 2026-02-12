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
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '@infrastructure/logging/index.js';
import { loadServerAuth } from '@infrastructure/auth/oauth.js';
import { loadGoogleServerAuth, type GoogleAuth } from '@infrastructure/auth/google-oauth.js';
import { loadOpenAIServerAuth } from '@infrastructure/auth/openai-auth.js';
import { detectProviderFromModel } from '@llm/providers/factory.js';
import { getSettings } from '@infrastructure/settings/index.js';
import type { ServerAuth } from '@infrastructure/auth/types.js';

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
  private cachedAccountLabel: string | undefined;

  constructor(config?: AuthProviderConfig) {
    this.cachedAuth = config?.initialAuth ?? null;
    this.cachedAccountLabel = this.cachedAuth?.type === 'oauth'
      ? this.cachedAuth.accountLabel
      : undefined;
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
   * Get authentication credentials for a given model.
   * Handles Codex OAuth tokens separately from standard auth.
   * Refreshes cached auth if OAuth tokens are expired.
   * Returns GoogleAuth for Google models (includes endpoint and projectId).
   */
  async getAuthForProvider(model: string): Promise<ServerAuth | GoogleAuth> {
    const providerType = detectProviderFromModel(model);

    if (providerType === 'openai-codex') {
      // Load Codex-specific auth (OAuth or API key)
      const codexAuth = await loadOpenAIServerAuth();
      if (!codexAuth) {
        throw new Error('OpenAI Codex not authenticated. Sign in via the iOS app, set OPENAI_API_KEY, or add apiKey to auth.json.');
      }
      logger.info('Loaded OpenAI Codex auth', { type: codexAuth.type });
      return codexAuth;
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
    // Refresh cache if needed (OAuth tokens expire or account switched)
    const currentAccountSetting = getSettings().server.anthropicAccount;
    const accountSwitched = currentAccountSetting !== this.cachedAccountLabel;

    if (!this.cachedAuth || accountSwitched || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
      if (accountSwitched) {
        logger.info('Anthropic account switched, refreshing auth', {
          from: this.cachedAccountLabel,
          to: currentAccountSetting,
        });
      }
      this.cachedAuth = await loadServerAuth();
      this.cachedAccountLabel = this.cachedAuth?.type === 'oauth'
        ? this.cachedAuth.accountLabel
        : undefined;
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
