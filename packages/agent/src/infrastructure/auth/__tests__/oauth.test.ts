/**
 * @fileoverview Tests for OAuth authentication
 *
 * TDD: Tests for PKCE flow, token management, and multi-account loadServerAuth
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock modules (hoisted to top by vitest)
vi.mock('@infrastructure/auth/unified.js', () => ({
  loadAuthStorage: vi.fn(),
  saveProviderOAuthTokens: vi.fn(),
  saveAccountOAuthTokens: vi.fn(),
}));

vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(),
}));

import {
  generatePKCE,
  getAuthorizationUrl,
  exchangeCodeForTokens,
  refreshOAuthToken,
  loadServerAuth,
  type OAuthTokens,
} from '../oauth.js';
import { loadAuthStorage, saveProviderOAuthTokens, saveAccountOAuthTokens } from '../unified.js';
import { getSettings } from '@infrastructure/settings/index.js';
import type { AuthStorage } from '../types.js';

const mockLoadAuthStorage = vi.mocked(loadAuthStorage);
const mockSaveProviderOAuthTokens = vi.mocked(saveProviderOAuthTokens);
const mockSaveAccountOAuthTokens = vi.mocked(saveAccountOAuthTokens);
const mockGetSettings = vi.mocked(getSettings);

function makeSettings(anthropicAccount?: string) {
  return {
    api: {
      anthropic: {
        authUrl: 'https://claude.ai/oauth/authorize',
        tokenUrl: 'https://claude.ai/oauth/token',
        redirectUri: 'https://console.anthropic.com/oauth/code/callback',
        clientId: 'test-client-id',
        scopes: ['org:create_api_key', 'user:inference', 'user:profile'],
        systemPromptPrefix: 'You are Claude Code',
        oauthBetaHeaders: 'oauth-2025-04-20',
        tokenExpiryBufferSeconds: 300,
      },
    },
    server: {
      anthropicAccount,
    },
  } as any;
}

// Set default settings for all tests
beforeEach(() => {
  mockGetSettings.mockReturnValue(makeSettings());
  mockSaveAccountOAuthTokens.mockResolvedValue(undefined);
  mockSaveProviderOAuthTokens.mockResolvedValue(undefined);
});

describe('OAuth Authentication', () => {
  describe('generatePKCE', () => {
    it('should generate verifier and challenge', () => {
      const { verifier, challenge } = generatePKCE();

      expect(verifier).toBeTruthy();
      expect(challenge).toBeTruthy();
      expect(verifier.length).toBeGreaterThanOrEqual(32);
    });

    it('should generate different values each time', () => {
      const first = generatePKCE();
      const second = generatePKCE();

      expect(first.verifier).not.toBe(second.verifier);
      expect(first.challenge).not.toBe(second.challenge);
    });

    it('should generate base64url-encoded values', () => {
      const { verifier, challenge } = generatePKCE();

      // Base64url should not contain +, /, or =
      expect(verifier).not.toMatch(/[+/=]/);
      expect(challenge).not.toMatch(/[+/=]/);
    });
  });

  describe('getAuthorizationUrl', () => {
    it('should construct valid authorization URL', () => {
      const challenge = 'test-challenge-12345';
      const url = getAuthorizationUrl(challenge);

      expect(url).toContain('claude.ai/oauth/authorize');
      expect(url).toContain('code_challenge=test-challenge-12345');
      expect(url).toContain('code_challenge_method=S256');
      expect(url).toContain('response_type=code');
    });

    it('should include required scopes', () => {
      const url = getAuthorizationUrl('test');
      const decodedUrl = decodeURIComponent(url);

      expect(decodedUrl).toContain('org:create_api_key');
      expect(decodedUrl).toContain('user:inference');
      expect(decodedUrl).toContain('user:profile');
    });

    it('should use Anthropic console callback redirect', () => {
      const url = getAuthorizationUrl('test');
      const decodedUrl = decodeURIComponent(url);

      expect(decodedUrl).toContain('redirect_uri=https://console.anthropic.com/oauth/code/callback');
    });

    it('should include state parameter', () => {
      const challenge = 'test-challenge';
      const url = getAuthorizationUrl(challenge);

      expect(url).toContain(`state=${challenge}`);
    });
  });

  describe('exchangeCodeForTokens', () => {
    beforeEach(() => {
      vi.stubGlobal('fetch', vi.fn());
    });

    it('should exchange code for tokens', async () => {
      const mockResponse = {
        access_token: 'sk-ant-oat-test-access-token',
        refresh_token: 'test-refresh-token',
        expires_in: 3600,
      };

      vi.mocked(fetch).mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(mockResponse),
      } as Response);

      const tokens = await exchangeCodeForTokens('auth-code', 'verifier');

      expect(tokens.accessToken).toBe('sk-ant-oat-test-access-token');
      expect(tokens.refreshToken).toBe('test-refresh-token');
      expect(tokens.expiresAt).toBeGreaterThan(Date.now());
    });

    it('should calculate expiry with buffer', async () => {
      const mockResponse = {
        access_token: 'test',
        refresh_token: 'test',
        expires_in: 3600, // 1 hour
      };

      vi.mocked(fetch).mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(mockResponse),
      } as Response);

      const tokens = await exchangeCodeForTokens('code', 'verifier');
      const expectedExpiry = Date.now() + (3600 - 300) * 1000; // 5 min buffer

      // Allow 1 second tolerance
      expect(tokens.expiresAt).toBeGreaterThan(expectedExpiry - 1000);
      expect(tokens.expiresAt).toBeLessThan(expectedExpiry + 1000);
    });

    it('should throw on failed exchange', async () => {
      vi.mocked(fetch).mockResolvedValue({
        ok: false,
        status: 400,
        statusText: 'Bad Request',
        json: () => Promise.resolve({ error: 'invalid_grant' }),
      } as Response);

      await expect(exchangeCodeForTokens('bad-code', 'verifier')).rejects.toThrow();
    });
  });

  describe('refreshOAuthToken', () => {
    beforeEach(() => {
      vi.stubGlobal('fetch', vi.fn());
    });

    it('should refresh tokens', async () => {
      const mockResponse = {
        access_token: 'sk-ant-oat-new-access-token',
        refresh_token: 'new-refresh-token',
        expires_in: 3600,
      };

      vi.mocked(fetch).mockResolvedValue({
        ok: true,
        json: () => Promise.resolve(mockResponse),
      } as Response);

      const tokens = await refreshOAuthToken('old-refresh-token');

      expect(tokens.accessToken).toBe('sk-ant-oat-new-access-token');
      expect(tokens.refreshToken).toBe('new-refresh-token');
    });

    it('should throw on expired refresh token', async () => {
      vi.mocked(fetch).mockResolvedValue({
        ok: false,
        status: 401,
        json: () => Promise.resolve({ error: 'invalid_grant' }),
      } as Response);

      await expect(refreshOAuthToken('expired-token')).rejects.toThrow();
    });
  });
});

describe('OAuthTokens type', () => {
  it('should define required fields', () => {
    const tokens: OAuthTokens = {
      accessToken: 'sk-ant-oat-test',
      refreshToken: 'refresh-test',
      expiresAt: Date.now() + 3600000,
    };

    expect(tokens.accessToken).toBeTruthy();
    expect(tokens.refreshToken).toBeTruthy();
    expect(tokens.expiresAt).toBeGreaterThan(0);
  });
});

// =============================================================================
// Multi-Account loadServerAuth() Tests
// =============================================================================

describe('loadServerAuth (multi-account)', () => {
  beforeEach(() => {
    delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
    mockGetSettings.mockReturnValue(makeSettings());
    mockSaveAccountOAuthTokens.mockResolvedValue(undefined);
    mockSaveProviderOAuthTokens.mockResolvedValue(undefined);
  });

  it('should select account matching anthropicAccount setting', async () => {
    mockGetSettings.mockReturnValue(makeSettings('Work'));
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          accounts: [
            { label: 'Personal', oauth: { accessToken: 'personal-token', refreshToken: 'r1', expiresAt: Date.now() + 3600000 } },
            { label: 'Work', oauth: { accessToken: 'work-token', refreshToken: 'r2', expiresAt: Date.now() + 3600000 } },
          ],
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    const auth = await loadServerAuth();
    expect(auth).not.toBeNull();
    expect(auth!.type).toBe('oauth');
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('work-token');
      expect(auth!.accountLabel).toBe('Work');
    }
  });

  it('should fall back to first account when no selection matches', async () => {
    mockGetSettings.mockReturnValue(makeSettings('NonExistent'));
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          accounts: [
            { label: 'Personal', oauth: { accessToken: 'personal-token', refreshToken: 'r1', expiresAt: Date.now() + 3600000 } },
          ],
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    const auth = await loadServerAuth();
    expect(auth).not.toBeNull();
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('personal-token');
      expect(auth!.accountLabel).toBe('Personal');
    }
  });

  it('should fall back to first account when no anthropicAccount set', async () => {
    mockGetSettings.mockReturnValue(makeSettings(undefined));
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          accounts: [
            { label: 'Default', oauth: { accessToken: 'default-token', refreshToken: 'r1', expiresAt: Date.now() + 3600000 } },
          ],
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    const auth = await loadServerAuth();
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('default-token');
      expect(auth!.accountLabel).toBe('Default');
    }
  });

  it('should refresh expired account tokens and save to correct account', async () => {
    mockGetSettings.mockReturnValue(makeSettings('Work'));
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          accounts: [
            { label: 'Work', oauth: { accessToken: 'expired', refreshToken: 'work-refresh', expiresAt: Date.now() - 1000 } },
          ],
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        access_token: 'new-work-token',
        refresh_token: 'new-work-refresh',
        expires_in: 3600,
      }),
    } as Response));

    const auth = await loadServerAuth();
    expect(auth).not.toBeNull();
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('new-work-token');
      expect(auth!.accountLabel).toBe('Work');
    }
    expect(mockSaveAccountOAuthTokens).toHaveBeenCalledWith(
      'anthropic',
      'Work',
      expect.objectContaining({ accessToken: 'new-work-token' })
    );
    expect(mockSaveProviderOAuthTokens).not.toHaveBeenCalled();
  });

  it('should use legacy oauth field when no accounts array exists (backwards compat)', async () => {
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          oauth: { accessToken: 'legacy-token', refreshToken: 'r1', expiresAt: Date.now() + 3600000 },
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    const auth = await loadServerAuth();
    expect(auth).not.toBeNull();
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('legacy-token');
      expect(auth!.accountLabel).toBeUndefined();
    }
  });

  it('should refresh legacy tokens and save via saveProviderOAuthTokens', async () => {
    mockLoadAuthStorage.mockResolvedValue({
      version: 1,
      providers: {
        anthropic: {
          oauth: { accessToken: 'expired', refreshToken: 'legacy-refresh', expiresAt: Date.now() - 1000 },
        },
      },
      lastUpdated: '',
    } as AuthStorage);

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        access_token: 'new-legacy-token',
        refresh_token: 'new-legacy-refresh',
        expires_in: 3600,
      }),
    } as Response));

    const auth = await loadServerAuth();
    if (auth!.type === 'oauth') {
      expect(auth!.accessToken).toBe('new-legacy-token');
      expect(auth!.accountLabel).toBeUndefined();
    }
    expect(mockSaveProviderOAuthTokens).toHaveBeenCalled();
    expect(mockSaveAccountOAuthTokens).not.toHaveBeenCalled();
  });
});
