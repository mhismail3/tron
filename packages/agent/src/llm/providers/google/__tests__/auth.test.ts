/**
 * @fileoverview Tests for Google OAuth token management
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
  categorizeError: vi.fn((e) => ({
    code: 'UNKNOWN',
    message: e?.message || String(e),
    retryable: false,
    category: 'unknown',
  })),
  LogErrorCategory: { PROVIDER_AUTH: 'provider_auth', PROVIDER_API: 'provider_api' },
}));

const mockRefreshGoogleOAuthToken = vi.fn();
const mockShouldRefreshGoogleTokens = vi.fn();
const mockDiscoverGoogleProject = vi.fn();

vi.mock('@infrastructure/auth/google-oauth.js', () => ({
  refreshGoogleOAuthToken: (...args: unknown[]) => mockRefreshGoogleOAuthToken(...args),
  shouldRefreshGoogleTokens: (...args: unknown[]) => mockShouldRefreshGoogleTokens(...args),
  discoverGoogleProject: (...args: unknown[]) => mockDiscoverGoogleProject(...args),
}));

const mockSaveProviderOAuthTokens = vi.fn();
const mockSaveProviderAuth = vi.fn();
const mockGetProviderAuthSync = vi.fn();

vi.mock('@infrastructure/auth/unified.js', () => ({
  saveProviderOAuthTokens: (...args: unknown[]) => mockSaveProviderOAuthTokens(...args),
  saveProviderAuth: (...args: unknown[]) => mockSaveProviderAuth(...args),
  getProviderAuthSync: (...args: unknown[]) => mockGetProviderAuthSync(...args),
}));

import {
  shouldRefreshTokens,
  ensureValidTokens,
  ensureProjectId,
  loadAuthMetadata,
} from '../auth.js';
import type { GoogleOAuthAuth, GoogleProviderAuth } from '../types.js';

describe('Google Auth', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockShouldRefreshGoogleTokens.mockReturnValue(false);
  });

  describe('shouldRefreshTokens', () => {
    it('returns false for api_key auth', () => {
      const auth: GoogleProviderAuth = { type: 'api_key', apiKey: 'test-key' };
      expect(shouldRefreshTokens(auth)).toBe(false);
    });

    it('delegates to shouldRefreshGoogleTokens for oauth', () => {
      mockShouldRefreshGoogleTokens.mockReturnValue(true);
      const auth: GoogleOAuthAuth = {
        type: 'oauth',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: Date.now() - 1000,
      };

      expect(shouldRefreshTokens(auth)).toBe(true);
      expect(mockShouldRefreshGoogleTokens).toHaveBeenCalledWith({
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: auth.expiresAt,
      });
    });
  });

  describe('ensureValidTokens', () => {
    const baseAuth: GoogleOAuthAuth = {
      type: 'oauth',
      accessToken: 'old-token',
      refreshToken: 'refresh-token',
      expiresAt: Date.now() + 3600000,
      endpoint: 'cloud-code-assist',
      projectId: 'proj-123',
    };

    it('returns original auth when refresh not needed', async () => {
      mockShouldRefreshGoogleTokens.mockReturnValue(false);

      const result = await ensureValidTokens(baseAuth);

      expect(result.refreshed).toBe(false);
      expect(result.auth).toBe(baseAuth);
    });

    it('refreshes tokens when needed and preserves projectId', async () => {
      mockShouldRefreshGoogleTokens.mockReturnValue(true);
      mockRefreshGoogleOAuthToken.mockResolvedValue({
        accessToken: 'new-token',
        refreshToken: 'new-refresh',
        expiresAt: Date.now() + 7200000,
      });

      const result = await ensureValidTokens(baseAuth);

      expect(result.refreshed).toBe(true);
      expect(result.auth.accessToken).toBe('new-token');
      expect(result.auth.refreshToken).toBe('new-refresh');
      expect(result.auth.projectId).toBe('proj-123');
      expect(result.auth.endpoint).toBe('cloud-code-assist');
      expect(mockSaveProviderOAuthTokens).toHaveBeenCalledWith('google', expect.objectContaining({
        accessToken: 'new-token',
      }));
    });

    it('throws on refresh failure', async () => {
      mockShouldRefreshGoogleTokens.mockReturnValue(true);
      mockRefreshGoogleOAuthToken.mockRejectedValue(new Error('Network error'));

      await expect(ensureValidTokens(baseAuth)).rejects.toThrow('Failed to refresh Google OAuth tokens');
    });

    it('defaults endpoint to cloud-code-assist', async () => {
      mockShouldRefreshGoogleTokens.mockReturnValue(true);
      mockRefreshGoogleOAuthToken.mockResolvedValue({
        accessToken: 'new',
        refreshToken: 'new-r',
        expiresAt: Date.now() + 3600000,
      });

      const authNoEndpoint: GoogleOAuthAuth = {
        ...baseAuth,
        endpoint: undefined,
      };

      const result = await ensureValidTokens(authNoEndpoint);
      expect(result.auth.endpoint).toBe('cloud-code-assist');
    });
  });

  describe('ensureProjectId', () => {
    const baseAuth: GoogleOAuthAuth = {
      type: 'oauth',
      accessToken: 'token',
      refreshToken: 'refresh',
      expiresAt: Date.now() + 3600000,
    };

    it('returns auth unchanged if projectId already set', async () => {
      const authWithProject = { ...baseAuth, projectId: 'existing-project' };
      const result = await ensureProjectId(authWithProject);
      expect(result).toBe(authWithProject);
      expect(mockDiscoverGoogleProject).not.toHaveBeenCalled();
    });

    it('discovers and persists projectId', async () => {
      mockDiscoverGoogleProject.mockResolvedValue('discovered-project-id');
      mockGetProviderAuthSync.mockReturnValue({ type: 'oauth', accessToken: 'stored' });

      const result = await ensureProjectId(baseAuth);

      expect(result.projectId).toBe('discovered-project-id');
      expect(mockSaveProviderAuth).toHaveBeenCalledWith('google', expect.objectContaining({
        projectId: 'discovered-project-id',
      }));
    });

    it('returns original auth when discovery returns null', async () => {
      mockDiscoverGoogleProject.mockResolvedValue(null);

      const result = await ensureProjectId(baseAuth);

      expect(result.projectId).toBeUndefined();
    });

    it('returns original auth on discovery error (fail-open)', async () => {
      mockDiscoverGoogleProject.mockRejectedValue(new Error('Network error'));

      const result = await ensureProjectId(baseAuth);

      expect(result).toBe(baseAuth);
    });
  });

  describe('loadAuthMetadata', () => {
    it('returns auth with defaults when no stored auth', () => {
      mockGetProviderAuthSync.mockReturnValue(null);

      const auth: GoogleOAuthAuth = {
        type: 'oauth',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: Date.now() + 3600000,
      };

      const result = loadAuthMetadata(auth);

      expect(result.endpoint).toBe('cloud-code-assist');
      expect(result.projectId).toBeUndefined();
    });

    it('loads endpoint and projectId from stored auth', () => {
      mockGetProviderAuthSync.mockReturnValue({
        type: 'oauth',
        endpoint: 'antigravity',
        projectId: 'stored-project',
      });

      const auth: GoogleOAuthAuth = {
        type: 'oauth',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: Date.now() + 3600000,
      };

      const result = loadAuthMetadata(auth);

      expect(result.endpoint).toBe('antigravity');
      expect(result.projectId).toBe('stored-project');
    });

    it('preserves explicit endpoint and projectId over stored', () => {
      mockGetProviderAuthSync.mockReturnValue({
        type: 'oauth',
        endpoint: 'antigravity',
        projectId: 'stored-project',
      });

      const auth: GoogleOAuthAuth = {
        type: 'oauth',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: Date.now() + 3600000,
        endpoint: 'cloud-code-assist',
        projectId: 'explicit-project',
      };

      const result = loadAuthMetadata(auth);

      expect(result.endpoint).toBe('cloud-code-assist');
      expect(result.projectId).toBe('explicit-project');
    });

    it('handles stored auth read errors gracefully', () => {
      mockGetProviderAuthSync.mockImplementation(() => { throw new Error('File not found'); });

      const auth: GoogleOAuthAuth = {
        type: 'oauth',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: Date.now() + 3600000,
      };

      const result = loadAuthMetadata(auth);

      expect(result.endpoint).toBe('cloud-code-assist');
    });
  });
});
