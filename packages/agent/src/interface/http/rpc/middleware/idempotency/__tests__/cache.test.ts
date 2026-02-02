/**
 * @fileoverview Tests for InMemoryIdempotencyCache
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { InMemoryIdempotencyCache, createIdempotencyCache } from '../cache.js';
import type { RpcResponse } from '../../../../../rpc/types.js';

describe('InMemoryIdempotencyCache', () => {
  let cache: InMemoryIdempotencyCache;

  const createResponse = (id: string, success = true): RpcResponse => ({
    id,
    success,
    result: success ? { data: 'test' } : undefined,
    error: success ? undefined : { code: 'ERROR', message: 'test error' },
  });

  beforeEach(() => {
    vi.useFakeTimers();
    cache = new InMemoryIdempotencyCache({ cleanupIntervalMs: 0 }); // Disable auto-cleanup for tests
  });

  afterEach(() => {
    cache.destroy();
    vi.useRealTimers();
  });

  describe('set and get', () => {
    it('should store and retrieve a response', () => {
      const response = createResponse('req-1');
      cache.set('key-1', response);

      const cached = cache.get('key-1');
      expect(cached).toBeDefined();
      expect(cached?.response).toEqual(response);
    });

    it('should return undefined for non-existent key', () => {
      expect(cache.get('non-existent')).toBeUndefined();
    });

    it('should return undefined for expired entry', () => {
      const response = createResponse('req-1');
      cache.set('key-1', response, 1000); // 1 second TTL

      // Advance time past TTL
      vi.advanceTimersByTime(1001);

      expect(cache.get('key-1')).toBeUndefined();
    });

    it('should track creation and expiration times', () => {
      const now = new Date('2024-01-01T00:00:00Z');
      vi.setSystemTime(now);

      const response = createResponse('req-1');
      cache.set('key-1', response, 5000);

      const cached = cache.get('key-1');
      expect(cached?.createdAt).toEqual(now);
      expect(cached?.expiresAt).toEqual(new Date(now.getTime() + 5000));
    });
  });

  describe('has', () => {
    it('should return true for existing non-expired entry', () => {
      cache.set('key-1', createResponse('req-1'));
      expect(cache.has('key-1')).toBe(true);
    });

    it('should return false for non-existent entry', () => {
      expect(cache.has('non-existent')).toBe(false);
    });

    it('should return false for expired entry', () => {
      cache.set('key-1', createResponse('req-1'), 1000);
      vi.advanceTimersByTime(1001);
      expect(cache.has('key-1')).toBe(false);
    });
  });

  describe('delete', () => {
    it('should remove an entry', () => {
      cache.set('key-1', createResponse('req-1'));
      expect(cache.delete('key-1')).toBe(true);
      expect(cache.get('key-1')).toBeUndefined();
    });

    it('should return false for non-existent entry', () => {
      expect(cache.delete('non-existent')).toBe(false);
    });
  });

  describe('cleanup', () => {
    it('should remove expired entries', () => {
      cache.set('key-1', createResponse('req-1'), 1000);
      cache.set('key-2', createResponse('req-2'), 5000);

      vi.advanceTimersByTime(2000);
      cache.cleanup();

      expect(cache.has('key-1')).toBe(false);
      expect(cache.has('key-2')).toBe(true);
    });
  });

  describe('stats', () => {
    it('should track hits and misses', () => {
      cache.set('key-1', createResponse('req-1'));

      cache.get('key-1'); // hit
      cache.get('key-1'); // hit
      cache.get('key-2'); // miss

      const stats = cache.stats();
      expect(stats.hits).toBe(2);
      expect(stats.misses).toBe(1);
      expect(stats.hitRate).toBeCloseTo(66.67, 1);
    });

    it('should return 0 hit rate with no requests', () => {
      const stats = cache.stats();
      expect(stats.hitRate).toBe(0);
    });

    it('should track size', () => {
      cache.set('key-1', createResponse('req-1'));
      cache.set('key-2', createResponse('req-2'));

      expect(cache.stats().size).toBe(2);
    });
  });

  describe('eviction', () => {
    it('should evict oldest entries when at capacity', () => {
      const smallCache = new InMemoryIdempotencyCache({
        maxSize: 5,
        cleanupIntervalMs: 0,
      });

      // Fill cache
      for (let i = 0; i < 5; i++) {
        vi.advanceTimersByTime(100); // Ensure different creation times
        smallCache.set(`key-${i}`, createResponse(`req-${i}`));
      }

      // Add one more - should evict oldest
      vi.advanceTimersByTime(100);
      smallCache.set('key-5', createResponse('req-5'));

      // key-0 should be evicted (oldest)
      expect(smallCache.has('key-0')).toBe(false);
      expect(smallCache.has('key-5')).toBe(true);

      smallCache.destroy();
    });
  });

  describe('factory function', () => {
    it('should create a cache with createIdempotencyCache', () => {
      const factoryCache = createIdempotencyCache({ cleanupIntervalMs: 0 });
      factoryCache.set('key-1', createResponse('req-1'));
      expect(factoryCache.get('key-1')).toBeDefined();
    });
  });
});
