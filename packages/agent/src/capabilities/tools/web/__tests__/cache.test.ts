/**
 * @fileoverview Tests for Web Cache
 *
 * TDD: Tests for URL content caching with TTL and max entries.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { WebCache } from '../cache.js';
import type { CachedFetchResult } from '../types.js';

describe('Web Cache', () => {
  let cache: WebCache;

  const createMockResult = (answer: string = 'Test answer'): CachedFetchResult => ({
    answer,
    source: {
      url: 'https://example.com',
      title: 'Test Page',
      fetchedAt: new Date().toISOString(),
    },
    subagentSessionId: 'session-123',
    cachedAt: Date.now(),
    expiresAt: Date.now() + 900000, // 15 minutes
  });

  beforeEach(() => {
    cache = new WebCache();
  });

  describe('basic operations', () => {
    it('should store and retrieve content', () => {
      const result = createMockResult();
      cache.set('https://example.com', 'what is this?', result);

      const retrieved = cache.get('https://example.com', 'what is this?');
      expect(retrieved).toBeDefined();
      expect(retrieved?.answer).toBe('Test answer');
    });

    it('should return undefined for missing entries', () => {
      const retrieved = cache.get('https://nonexistent.com', 'query');
      expect(retrieved).toBeUndefined();
    });

    it('should use URL + prompt hash as key', () => {
      const result1 = createMockResult('Answer 1');
      const result2 = createMockResult('Answer 2');

      cache.set('https://example.com', 'prompt 1', result1);
      cache.set('https://example.com', 'prompt 2', result2);

      const retrieved1 = cache.get('https://example.com', 'prompt 1');
      const retrieved2 = cache.get('https://example.com', 'prompt 2');

      expect(retrieved1?.answer).toBe('Answer 1');
      expect(retrieved2?.answer).toBe('Answer 2');
    });

    it('should overwrite existing entries with same key', () => {
      const result1 = createMockResult('First');
      const result2 = createMockResult('Second');

      cache.set('https://example.com', 'prompt', result1);
      cache.set('https://example.com', 'prompt', result2);

      const retrieved = cache.get('https://example.com', 'prompt');
      expect(retrieved?.answer).toBe('Second');
    });
  });

  describe('TTL expiration', () => {
    it('should return undefined for expired entries', async () => {
      // Create cache with very short TTL
      const shortTtlCache = new WebCache({ ttl: 10 }); // 10ms TTL

      const result = createMockResult();
      shortTtlCache.set('https://example.com', 'prompt', result);

      // Wait for expiration
      await new Promise((resolve) => setTimeout(resolve, 20));

      const retrieved = shortTtlCache.get('https://example.com', 'prompt');
      expect(retrieved).toBeUndefined();
    });

    it('should clean up expired entries', async () => {
      const shortTtlCache = new WebCache({ ttl: 10 });

      shortTtlCache.set('https://example1.com', 'p1', createMockResult('1'));
      shortTtlCache.set('https://example2.com', 'p2', createMockResult('2'));

      expect(shortTtlCache.size()).toBe(2);

      // Wait for expiration
      await new Promise((resolve) => setTimeout(resolve, 20));

      // Cleanup runs on get or manually
      shortTtlCache.cleanup();

      expect(shortTtlCache.size()).toBe(0);
    });
  });

  describe('max entries limit', () => {
    it('should respect max entries limit', () => {
      const smallCache = new WebCache({ maxEntries: 3 });

      smallCache.set('https://example1.com', 'p', createMockResult('1'));
      smallCache.set('https://example2.com', 'p', createMockResult('2'));
      smallCache.set('https://example3.com', 'p', createMockResult('3'));
      smallCache.set('https://example4.com', 'p', createMockResult('4'));

      expect(smallCache.size()).toBeLessThanOrEqual(3);
    });

    it('should evict oldest entries when limit reached', () => {
      const smallCache = new WebCache({ maxEntries: 2, ttl: 60000 });

      smallCache.set('https://example1.com', 'p', createMockResult('1'));
      smallCache.set('https://example2.com', 'p', createMockResult('2'));
      smallCache.set('https://example3.com', 'p', createMockResult('3'));

      // First entry should be evicted
      const first = smallCache.get('https://example1.com', 'p');
      expect(first).toBeUndefined();

      // Newer entries should still exist
      const third = smallCache.get('https://example3.com', 'p');
      expect(third?.answer).toBe('3');
    });
  });

  describe('cache statistics', () => {
    it('should track cache hits', () => {
      cache.set('https://example.com', 'p', createMockResult());

      cache.get('https://example.com', 'p'); // hit
      cache.get('https://example.com', 'p'); // hit

      const stats = cache.getStats();
      expect(stats.hits).toBe(2);
    });

    it('should track cache misses', () => {
      cache.get('https://nonexistent1.com', 'p'); // miss
      cache.get('https://nonexistent2.com', 'p'); // miss

      const stats = cache.getStats();
      expect(stats.misses).toBe(2);
    });

    it('should calculate hit rate', () => {
      cache.set('https://example.com', 'p', createMockResult());

      cache.get('https://example.com', 'p'); // hit
      cache.get('https://example.com', 'p'); // hit
      cache.get('https://missing.com', 'p'); // miss
      cache.get('https://missing2.com', 'p'); // miss

      const stats = cache.getStats();
      expect(stats.hitRate).toBe(0.5); // 2 hits / 4 total
    });

    it('should report correct size', () => {
      expect(cache.size()).toBe(0);

      cache.set('https://example1.com', 'p', createMockResult('1'));
      expect(cache.size()).toBe(1);

      cache.set('https://example2.com', 'p', createMockResult('2'));
      expect(cache.size()).toBe(2);
    });

    it('should handle zero operations for hit rate', () => {
      const stats = cache.getStats();
      expect(stats.hitRate).toBe(0);
    });
  });

  describe('clear and delete', () => {
    it('should clear all entries', () => {
      cache.set('https://example1.com', 'p', createMockResult('1'));
      cache.set('https://example2.com', 'p', createMockResult('2'));

      expect(cache.size()).toBe(2);

      cache.clear();

      expect(cache.size()).toBe(0);
    });

    it('should delete specific entry', () => {
      cache.set('https://example1.com', 'p', createMockResult('1'));
      cache.set('https://example2.com', 'p', createMockResult('2'));

      const deleted = cache.delete('https://example1.com', 'p');
      expect(deleted).toBe(true);

      expect(cache.get('https://example1.com', 'p')).toBeUndefined();
      expect(cache.get('https://example2.com', 'p')).toBeDefined();
    });

    it('should return false when deleting non-existent entry', () => {
      const deleted = cache.delete('https://nonexistent.com', 'p');
      expect(deleted).toBe(false);
    });

    it('should reset stats on clear', () => {
      cache.set('https://example.com', 'p', createMockResult());
      cache.get('https://example.com', 'p'); // hit
      cache.get('https://missing.com', 'p'); // miss

      cache.clear();

      const stats = cache.getStats();
      expect(stats.hits).toBe(0);
      expect(stats.misses).toBe(0);
    });
  });

  describe('has method', () => {
    it('should return true for existing entry', () => {
      cache.set('https://example.com', 'p', createMockResult());
      expect(cache.has('https://example.com', 'p')).toBe(true);
    });

    it('should return false for non-existent entry', () => {
      expect(cache.has('https://nonexistent.com', 'p')).toBe(false);
    });

    it('should return false for expired entry', async () => {
      const shortTtlCache = new WebCache({ ttl: 10 });
      shortTtlCache.set('https://example.com', 'p', createMockResult());

      await new Promise((resolve) => setTimeout(resolve, 20));

      expect(shortTtlCache.has('https://example.com', 'p')).toBe(false);
    });
  });

  describe('configuration', () => {
    it('should create cache with custom TTL', () => {
      const customCache = new WebCache({ ttl: 60000 }); // 1 minute
      expect(customCache).toBeDefined();
    });

    it('should create cache with custom max entries', () => {
      const customCache = new WebCache({ maxEntries: 50 });
      expect(customCache).toBeDefined();
    });

    it('should use default TTL of 15 minutes', () => {
      const defaultCache = new WebCache();
      // We can't directly test TTL value, but we can verify it works
      defaultCache.set('https://example.com', 'p', createMockResult());
      expect(defaultCache.get('https://example.com', 'p')).toBeDefined();
    });
  });
});
