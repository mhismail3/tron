/**
 * @fileoverview Tests for Anthropic auth module
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
    trace: vi.fn(),
  })),
}));

vi.mock('@infrastructure/auth/oauth.js', () => ({
  shouldRefreshTokens: vi.fn(),
  refreshOAuthToken: vi.fn(),
}));

vi.mock('@infrastructure/auth/unified.js', () => ({
  saveAccountOAuthTokens: vi.fn(),
  saveProviderOAuthTokens: vi.fn(),
}));

import { getOAuthHeaders, ensureValidTokens } from '../auth.js';
import { shouldRefreshTokens, refreshOAuthToken } from '@infrastructure/auth/oauth.js';
import { saveAccountOAuthTokens, saveProviderOAuthTokens } from '@infrastructure/auth/unified.js';
import type { AnthropicProviderSettings } from '../types.js';

describe('Anthropic Auth', () => {
  const mockSettings: AnthropicProviderSettings = {
    api: {
      systemPromptPrefix: "You are Claude Code.",
      oauthBetaHeaders: 'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14',
      tokenExpiryBufferSeconds: 300,
    },
    models: { default: 'claude-opus-4-6' },
    retry: { maxRetries: 3, baseDelayMs: 1000, maxDelayMs: 60000, jitterFactor: 0.2 },
  };

  beforeEach(() => {
    vi.mocked(shouldRefreshTokens).mockReturnValue(false);
    vi.mocked(refreshOAuthToken).mockResolvedValue({
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      expiresAt: Date.now() + 3600000,
    });
    vi.mocked(saveAccountOAuthTokens).mockResolvedValue(undefined);
    vi.mocked(saveProviderOAuthTokens).mockResolvedValue(undefined);
  });

  describe('getOAuthHeaders', () => {
    it('sends only oauth-2025-04-20 for models that do not require thinking beta headers', () => {
      const headers = getOAuthHeaders('claude-opus-4-6', mockSettings);

      expect(headers['anthropic-beta']).toBe('oauth-2025-04-20');
      expect(headers['accept']).toBe('application/json');
      expect(headers['anthropic-dangerous-direct-browser-access']).toBe('true');
    });

    it('sends all beta headers for models that require thinking beta headers', () => {
      const headers = getOAuthHeaders('claude-opus-4-5-20251101', mockSettings);

      expect(headers['anthropic-beta']).toBe(
        'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14'
      );
    });

    it('sends all beta headers for claude-sonnet-4-5', () => {
      const headers = getOAuthHeaders('claude-sonnet-4-5-20250929', mockSettings);

      expect(headers['anthropic-beta']).toBe(
        'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14'
      );
    });

    it('sends all beta headers for unknown models (defensive)', () => {
      const headers = getOAuthHeaders('claude-unknown-future-model', mockSettings);

      expect(headers['anthropic-beta']).toBe(
        'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14'
      );
    });
  });

  describe('ensureValidTokens', () => {
    const validTokens = {
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      expiresAt: Date.now() + 3600000,
    };

    it('returns original tokens when no refresh needed', async () => {
      vi.mocked(shouldRefreshTokens).mockReturnValue(false);

      const result = await ensureValidTokens(validTokens);

      expect(result.refreshed).toBe(false);
      expect(result.tokens).toBe(validTokens);
      expect(refreshOAuthToken).not.toHaveBeenCalled();
    });

    it('refreshes tokens when shouldRefreshTokens returns true', async () => {
      vi.mocked(shouldRefreshTokens).mockReturnValue(true);

      const result = await ensureValidTokens(validTokens);

      expect(result.refreshed).toBe(true);
      expect(result.tokens.accessToken).toBe('new-access');
      expect(result.tokens.refreshToken).toBe('new-refresh');
      expect(refreshOAuthToken).toHaveBeenCalledWith('old-refresh');
    });

    it('persists tokens to provider location by default', async () => {
      vi.mocked(shouldRefreshTokens).mockReturnValue(true);

      await ensureValidTokens(validTokens);

      expect(saveProviderOAuthTokens).toHaveBeenCalledWith('anthropic', expect.objectContaining({
        accessToken: 'new-access',
      }));
      expect(saveAccountOAuthTokens).not.toHaveBeenCalled();
    });

    it('persists tokens to account location when accountLabel provided', async () => {
      vi.mocked(shouldRefreshTokens).mockReturnValue(true);

      await ensureValidTokens(validTokens, { accountLabel: 'work-account' });

      expect(saveAccountOAuthTokens).toHaveBeenCalledWith(
        'anthropic',
        'work-account',
        expect.objectContaining({ accessToken: 'new-access' })
      );
      expect(saveProviderOAuthTokens).not.toHaveBeenCalled();
    });

    it('propagates refresh errors', async () => {
      vi.mocked(shouldRefreshTokens).mockReturnValue(true);
      vi.mocked(refreshOAuthToken).mockRejectedValue(new Error('Network timeout'));

      await expect(ensureValidTokens(validTokens)).rejects.toThrow('Network timeout');
    });
  });
});
