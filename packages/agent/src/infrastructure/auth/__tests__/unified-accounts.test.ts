/**
 * @fileoverview Tests for multi-account auth storage
 *
 * Tests saveAccountOAuthTokens and getAccountLabels.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as os from 'os';
import * as path from 'path';
import * as fs from 'fs';
import { randomUUID } from 'crypto';

// Mock settings to control data dir
vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn().mockReturnValue({
    api: { anthropic: { tokenExpiryBufferSeconds: 300 } },
  }),
  getTronDataDir: vi.fn(),
}));

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
  categorizeError: vi.fn().mockReturnValue({
    code: 'UNKNOWN',
    message: 'test',
    retryable: false,
  }),
  LogErrorCategory: { PROVIDER_AUTH: 'PROVIDER_AUTH' },
}));

import { getTronDataDir } from '@infrastructure/settings/index.js';
import {
  saveAccountOAuthTokens,
  getAccountLabels,
  loadAuthStorage,
  saveAuthStorage,
} from '../unified.js';
import type { AuthStorage, OAuthTokens } from '../types.js';

const mockGetTronDataDir = vi.mocked(getTronDataDir);

describe('Multi-Account Auth Storage', () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `tron-test-${randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    mockGetTronDataDir.mockReturnValue(tmpDir);
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const makeTokens = (prefix: string): OAuthTokens => ({
    accessToken: `${prefix}-access`,
    refreshToken: `${prefix}-refresh`,
    expiresAt: Date.now() + 3600000,
  });

  describe('saveAccountOAuthTokens', () => {
    it('should create accounts array when none exists', async () => {
      // Seed with a provider that has no accounts
      const auth: AuthStorage = {
        version: 1,
        providers: {
          anthropic: { oauth: makeTokens('legacy') },
        },
        lastUpdated: new Date().toISOString(),
      };
      await saveAuthStorage(auth);

      await saveAccountOAuthTokens('anthropic', 'Personal', makeTokens('personal'));

      const loaded = await loadAuthStorage();
      expect(loaded?.providers.anthropic?.accounts).toHaveLength(1);
      expect(loaded?.providers.anthropic?.accounts?.[0]?.label).toBe('Personal');
      expect(loaded?.providers.anthropic?.accounts?.[0]?.oauth.accessToken).toBe('personal-access');
      // Legacy oauth field should be preserved
      expect(loaded?.providers.anthropic?.oauth?.accessToken).toBe('legacy-access');
    });

    it('should update existing account by label', async () => {
      const auth: AuthStorage = {
        version: 1,
        providers: {
          anthropic: {
            accounts: [
              { label: 'Personal', oauth: makeTokens('old-personal') },
              { label: 'Work', oauth: makeTokens('work') },
            ],
          },
        },
        lastUpdated: new Date().toISOString(),
      };
      await saveAuthStorage(auth);

      const newTokens = makeTokens('new-personal');
      await saveAccountOAuthTokens('anthropic', 'Personal', newTokens);

      const loaded = await loadAuthStorage();
      expect(loaded?.providers.anthropic?.accounts).toHaveLength(2);
      expect(loaded?.providers.anthropic?.accounts?.[0]?.oauth.accessToken).toBe('new-personal-access');
      // Work account untouched
      expect(loaded?.providers.anthropic?.accounts?.[1]?.oauth.accessToken).toBe('work-access');
    });

    it('should append new account when label does not exist', async () => {
      const auth: AuthStorage = {
        version: 1,
        providers: {
          anthropic: {
            accounts: [
              { label: 'Personal', oauth: makeTokens('personal') },
            ],
          },
        },
        lastUpdated: new Date().toISOString(),
      };
      await saveAuthStorage(auth);

      await saveAccountOAuthTokens('anthropic', 'Work', makeTokens('work'));

      const loaded = await loadAuthStorage();
      expect(loaded?.providers.anthropic?.accounts).toHaveLength(2);
      expect(loaded?.providers.anthropic?.accounts?.[1]?.label).toBe('Work');
    });

    it('should create provider entry when provider does not exist', async () => {
      // Empty auth.json
      const auth: AuthStorage = {
        version: 1,
        providers: {},
        lastUpdated: new Date().toISOString(),
      };
      await saveAuthStorage(auth);

      await saveAccountOAuthTokens('anthropic', 'Personal', makeTokens('personal'));

      const loaded = await loadAuthStorage();
      expect(loaded?.providers.anthropic?.accounts).toHaveLength(1);
      expect(loaded?.providers.anthropic?.accounts?.[0]?.label).toBe('Personal');
    });

    it('should create auth.json when file does not exist', async () => {
      await saveAccountOAuthTokens('anthropic', 'Personal', makeTokens('personal'));

      const loaded = await loadAuthStorage();
      expect(loaded?.providers.anthropic?.accounts).toHaveLength(1);
    });
  });

  describe('getAccountLabels', () => {
    it('should return labels from accounts array', () => {
      const auth: AuthStorage = {
        version: 1,
        providers: {
          anthropic: {
            accounts: [
              { label: 'Personal', oauth: makeTokens('personal') },
              { label: 'Work', oauth: makeTokens('work') },
            ],
          },
        },
        lastUpdated: new Date().toISOString(),
      };
      fs.writeFileSync(
        path.join(tmpDir, 'auth.json'),
        JSON.stringify(auth, null, 2),
        { mode: 0o600 }
      );

      const labels = getAccountLabels('anthropic');
      expect(labels).toEqual(['Personal', 'Work']);
    });

    it('should return empty array when no accounts configured', () => {
      const auth: AuthStorage = {
        version: 1,
        providers: {
          anthropic: { oauth: makeTokens('legacy') },
        },
        lastUpdated: new Date().toISOString(),
      };
      fs.writeFileSync(
        path.join(tmpDir, 'auth.json'),
        JSON.stringify(auth, null, 2),
        { mode: 0o600 }
      );

      const labels = getAccountLabels('anthropic');
      expect(labels).toEqual([]);
    });

    it('should return empty array when provider does not exist', () => {
      const auth: AuthStorage = {
        version: 1,
        providers: {},
        lastUpdated: new Date().toISOString(),
      };
      fs.writeFileSync(
        path.join(tmpDir, 'auth.json'),
        JSON.stringify(auth, null, 2),
        { mode: 0o600 }
      );

      const labels = getAccountLabels('anthropic');
      expect(labels).toEqual([]);
    });

    it('should return empty array when auth.json does not exist', () => {
      const labels = getAccountLabels('anthropic');
      expect(labels).toEqual([]);
    });
  });
});
