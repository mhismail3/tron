/**
 * @fileoverview Tests for HealthChecker
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { HealthChecker, createHealthChecker } from '../health-checker.js';
import type { DeploymentControllerConfig } from '../types.js';

describe('HealthChecker', () => {
  let checker: HealthChecker;
  const mockConfig: DeploymentControllerConfig = {
    projectRoot: '/test/path',
    betaPort: 8082,
    betaHealthPort: 8083,
    prodPort: 8080,
    prodHealthPort: 8081,
    healthCheckTimeoutMs: 5000,
  };

  beforeEach(() => {
    checker = new HealthChecker(mockConfig);
    vi.stubGlobal('fetch', vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe('check', () => {
    it('should return healthy result for successful health check', async () => {
      vi.mocked(fetch).mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'ok', version: '1.0.0' }),
      } as Response);

      const result = await checker.check('prod');

      expect(result.healthy).toBe(true);
      expect(result.version).toBe('1.0.0');
      expect(result.responseTimeMs).toBeDefined();
      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:8081/health',
        expect.objectContaining({
          headers: { Accept: 'application/json' },
        })
      );
    });

    it('should use beta port for beta target', async () => {
      vi.mocked(fetch).mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'ok' }),
      } as Response);

      await checker.check('beta');

      expect(fetch).toHaveBeenCalledWith(
        'http://localhost:8083/health',
        expect.anything()
      );
    });

    it('should return unhealthy for non-ok response', async () => {
      vi.mocked(fetch).mockResolvedValueOnce({
        ok: false,
        status: 503,
        statusText: 'Service Unavailable',
      } as Response);

      const result = await checker.check('prod');

      expect(result.healthy).toBe(false);
      expect(result.error).toContain('503');
    });

    it('should return unhealthy for non-ok status in body', async () => {
      vi.mocked(fetch).mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'error', message: 'DB connection failed' }),
      } as Response);

      const result = await checker.check('prod');

      expect(result.healthy).toBe(false);
      expect(result.error).toContain('error');
    });

    it('should return unhealthy on network error', async () => {
      vi.mocked(fetch).mockRejectedValueOnce(new Error('Connection refused'));

      const result = await checker.check('prod');

      expect(result.healthy).toBe(false);
      expect(result.error).toBe('Connection refused');
    });

    it('should return unhealthy on timeout', async () => {
      const abortError = new Error('Aborted');
      abortError.name = 'AbortError';
      vi.mocked(fetch).mockRejectedValueOnce(abortError);

      const result = await checker.check('prod');

      expect(result.healthy).toBe(false);
      expect(result.error).toContain('timed out');
    });
  });

  describe('waitForHealthy', () => {
    it('should return immediately if healthy', async () => {
      vi.mocked(fetch).mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'ok', version: '1.0.0' }),
      } as Response);

      const result = await checker.waitForHealthy('prod', {
        maxAttempts: 3,
        delayMs: 100,
      });

      expect(result.healthy).toBe(true);
      expect(fetch).toHaveBeenCalledTimes(1);
    });

    it('should retry until healthy', async () => {
      vi.mocked(fetch)
        .mockRejectedValueOnce(new Error('Connection refused'))
        .mockRejectedValueOnce(new Error('Connection refused'))
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ status: 'ok' }),
        } as Response);

      const result = await checker.waitForHealthy('prod', {
        maxAttempts: 5,
        delayMs: 10,
      });

      expect(result.healthy).toBe(true);
      expect(fetch).toHaveBeenCalledTimes(3);
    });

    it('should return unhealthy after max attempts', async () => {
      vi.mocked(fetch).mockRejectedValue(new Error('Connection refused'));

      const result = await checker.waitForHealthy('prod', {
        maxAttempts: 3,
        delayMs: 10,
      });

      expect(result.healthy).toBe(false);
      expect(result.error).toContain('did not become healthy');
      expect(fetch).toHaveBeenCalledTimes(3);
    });
  });

  describe('factory function', () => {
    it('should create checker with createHealthChecker', async () => {
      const factoryChecker = createHealthChecker(mockConfig);

      vi.mocked(fetch).mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'ok' }),
      } as Response);

      const result = await factoryChecker.check('prod');
      expect(result.healthy).toBe(true);
    });
  });
});
