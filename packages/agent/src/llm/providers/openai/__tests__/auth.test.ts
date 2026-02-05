/**
 * @fileoverview Tests for OpenAI OAuth authentication
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
}));

const mockSaveProviderOAuthTokens = vi.fn();

vi.mock('@infrastructure/auth/index.js', () => ({
  saveProviderOAuthTokens: (...args: unknown[]) => mockSaveProviderOAuthTokens(...args),
}));

import {
  extractAccountId,
  shouldRefreshTokens,
  refreshTokens,
  OpenAITokenManager,
} from '../auth.js';
import type { OpenAIOAuth } from '../types.js';

describe('OpenAI Auth', () => {
  const originalFetch = global.fetch;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  describe('extractAccountId', () => {
    it('extracts account ID from valid JWT', () => {
      const payload = {
        'https://api.openai.com/auth': { chatgpt_account_id: 'acc_12345' },
      };
      const encoded = Buffer.from(JSON.stringify(payload)).toString('base64');
      const token = `header.${encoded}.signature`;

      expect(extractAccountId(token)).toBe('acc_12345');
    });

    it('returns empty string for invalid JWT format', () => {
      expect(extractAccountId('not-a-jwt')).toBe('');
      expect(extractAccountId('')).toBe('');
    });

    it('returns empty string when auth claims are missing', () => {
      const payload = { sub: 'user123' };
      const encoded = Buffer.from(JSON.stringify(payload)).toString('base64');
      const token = `header.${encoded}.signature`;

      expect(extractAccountId(token)).toBe('');
    });

    it('returns empty string for malformed base64', () => {
      expect(extractAccountId('header.!!!invalid!!!.signature')).toBe('');
    });
  });

  describe('shouldRefreshTokens', () => {
    it('returns true when token is expired', () => {
      const expiredAt = Date.now() - 1000;
      expect(shouldRefreshTokens(expiredAt)).toBe(true);
    });

    it('returns true when within default 5-minute buffer', () => {
      const expiresAt = Date.now() + 200 * 1000; // 200 seconds from now (< 300s buffer)
      expect(shouldRefreshTokens(expiresAt)).toBe(true);
    });

    it('returns false when well before expiry', () => {
      const expiresAt = Date.now() + 3600000; // 1 hour from now
      expect(shouldRefreshTokens(expiresAt)).toBe(false);
    });

    it('respects custom buffer from settings', () => {
      const expiresAt = Date.now() + 100 * 1000; // 100 seconds from now

      // With default 300s buffer, should need refresh
      expect(shouldRefreshTokens(expiresAt)).toBe(true);

      // With 60s buffer, should NOT need refresh
      expect(shouldRefreshTokens(expiresAt, { tokenExpiryBufferSeconds: 60 })).toBe(false);
    });
  });

  describe('refreshTokens', () => {
    it('refreshes tokens and persists them', async () => {
      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          access_token: 'new-access-token',
          refresh_token: 'new-refresh-token',
          expires_in: 3600,
        }),
      });

      const result = await refreshTokens('old-refresh-token');

      expect(result.accessToken).toBe('new-access-token');
      expect(result.refreshToken).toBe('new-refresh-token');
      expect(result.expiresAt).toBeGreaterThan(Date.now());
      expect(mockSaveProviderOAuthTokens).toHaveBeenCalledWith('openai-codex', result);
    });

    it('uses default token URL and client ID', async () => {
      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          access_token: 'new',
          refresh_token: 'new-r',
          expires_in: 3600,
        }),
      });

      await refreshTokens('refresh-token');

      expect(global.fetch).toHaveBeenCalledWith(
        'https://auth.openai.com/oauth/token',
        expect.objectContaining({
          method: 'POST',
          body: expect.stringContaining('"client_id":"app_EMoamEEZ73f0CkXaXp7hrann"'),
        })
      );
    });

    it('uses custom settings for token URL and client ID', async () => {
      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          access_token: 'new',
          refresh_token: 'new-r',
          expires_in: 3600,
        }),
      });

      await refreshTokens('refresh-token', {
        tokenUrl: 'https://custom.auth.com/token',
        clientId: 'custom-client',
      });

      expect(global.fetch).toHaveBeenCalledWith(
        'https://custom.auth.com/token',
        expect.objectContaining({
          body: expect.stringContaining('"client_id":"custom-client"'),
        })
      );
    });

    it('throws on failed refresh', async () => {
      global.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 401,
        text: async () => 'Invalid refresh token',
      });

      await expect(refreshTokens('bad-token')).rejects.toThrow('Token refresh failed: 401');
    });
  });

  describe('OpenAITokenManager', () => {
    const createAuth = (overrides?: Partial<OpenAIOAuth>): OpenAIOAuth => ({
      type: 'oauth',
      accessToken: 'test-token',
      refreshToken: 'test-refresh',
      expiresAt: Date.now() + 3600000,
      ...overrides,
    });

    it('exposes access token', () => {
      const auth = createAuth();
      const manager = new OpenAITokenManager(auth);

      expect(manager.accessToken).toBe('test-token');
    });

    it('exposes current auth state', () => {
      const auth = createAuth();
      const manager = new OpenAITokenManager(auth);

      expect(manager.currentAuth).toBe(auth);
    });

    it('does not refresh when tokens are valid', async () => {
      global.fetch = vi.fn();
      const auth = createAuth({ expiresAt: Date.now() + 3600000 });
      const manager = new OpenAITokenManager(auth);

      await manager.ensureValidTokens();

      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('refreshes and updates auth when tokens expired', async () => {
      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          access_token: 'refreshed-token',
          refresh_token: 'refreshed-refresh',
          expires_in: 7200,
        }),
      });

      const auth = createAuth({ expiresAt: Date.now() - 1000 });
      const manager = new OpenAITokenManager(auth);

      await manager.ensureValidTokens();

      expect(manager.accessToken).toBe('refreshed-token');
      expect(manager.currentAuth.refreshToken).toBe('refreshed-refresh');
    });

    describe('buildHeaders', () => {
      it('includes required headers', () => {
        const auth = createAuth();
        const manager = new OpenAITokenManager(auth);

        const headers = manager.buildHeaders();

        expect(headers['Authorization']).toBe('Bearer test-token');
        expect(headers['Content-Type']).toBe('application/json');
        expect(headers['Accept']).toBe('text/event-stream');
        expect(headers['openai-beta']).toBe('responses=experimental');
        expect(headers['openai-originator']).toBe('codex_cli_rs');
      });

      it('includes account ID from JWT when available', () => {
        const payload = {
          'https://api.openai.com/auth': { chatgpt_account_id: 'acc_test' },
        };
        const encoded = Buffer.from(JSON.stringify(payload)).toString('base64');
        const token = `header.${encoded}.signature`;

        const auth = createAuth({ accessToken: token });
        const manager = new OpenAITokenManager(auth);

        const headers = manager.buildHeaders();

        expect(headers['chatgpt-account-id']).toBe('acc_test');
      });

      it('omits account ID header when JWT has no account', () => {
        const auth = createAuth({ accessToken: 'simple-token' });
        const manager = new OpenAITokenManager(auth);

        const headers = manager.buildHeaders();

        expect(headers).not.toHaveProperty('chatgpt-account-id');
      });
    });
  });
});
