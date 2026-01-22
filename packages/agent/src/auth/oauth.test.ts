/**
 * @fileoverview Tests for OAuth authentication
 *
 * TDD: Tests for PKCE flow and token management
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  generatePKCE,
  getAuthorizationUrl,
  exchangeCodeForTokens,
  refreshOAuthToken,
  type OAuthTokens,
} from '../../src/auth/oauth.js';

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
