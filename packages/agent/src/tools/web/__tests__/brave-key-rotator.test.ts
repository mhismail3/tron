/**
 * @fileoverview Tests for BraveKeyRotator
 *
 * TDD: Tests for multi-key rate limiting with 1 RPS per key.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { BraveKeyRotator, KeyRotatorError } from '../brave-key-rotator.js';

describe('BraveKeyRotator', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('constructor', () => {
    it('should throw error when initialized with no keys', () => {
      expect(() => new BraveKeyRotator([])).toThrow('At least one API key is required');
    });

    it('should accept a single key', () => {
      const rotator = new BraveKeyRotator(['key1']);
      expect(rotator.getStatus().total).toBe(1);
    });

    it('should accept multiple keys', () => {
      const rotator = new BraveKeyRotator(['key1', 'key2', 'key3']);
      expect(rotator.getStatus().total).toBe(3);
    });

    it('should filter out empty strings', () => {
      const rotator = new BraveKeyRotator(['key1', '', 'key2', '  ']);
      expect(rotator.getStatus().total).toBe(2);
    });

    it('should accept custom rpsLimit', () => {
      const rotator = new BraveKeyRotator(['key1'], { rpsLimit: 2 });
      expect(rotator).toBeDefined();
    });
  });

  describe('acquireKey', () => {
    it('should return a key immediately when available', async () => {
      const rotator = new BraveKeyRotator(['key1']);
      const key = await rotator.acquireKey();
      expect(key).toBe('key1');
    });

    it('should round-robin through multiple keys', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2', 'key3']);

      const key1 = await rotator.acquireKey();
      rotator.releaseKey(key1);
      await vi.advanceTimersByTimeAsync(1001); // Wait for rate limit

      const key2 = await rotator.acquireKey();
      rotator.releaseKey(key2);
      await vi.advanceTimersByTimeAsync(1001);

      const key3 = await rotator.acquireKey();
      rotator.releaseKey(key3);
      await vi.advanceTimersByTimeAsync(1001);

      const key4 = await rotator.acquireKey();

      // Keys should cycle through
      expect(key1).toBe('key1');
      expect(key2).toBe('key2');
      expect(key3).toBe('key3');
      expect(key4).toBe('key1');
    });

    it('should wait when all keys are rate limited', async () => {
      const rotator = new BraveKeyRotator(['key1']);

      // First call succeeds immediately
      const key1 = await rotator.acquireKey();
      rotator.releaseKey(key1);

      // Second call should wait - start the promise but don't await yet
      const acquirePromise = rotator.acquireKey();

      // Advance time to release the rate limit
      await vi.advanceTimersByTimeAsync(1001);

      const key2 = await acquirePromise;
      expect(key2).toBe('key1');
    });

    it('should timeout if no key available within timeout period', async () => {
      const rotator = new BraveKeyRotator(['key1']);

      // Acquire and release to start rate limiting
      const key1 = await rotator.acquireKey();
      rotator.releaseKey(key1);

      // Try to acquire with short timeout
      // Attach .catch() immediately to prevent unhandled rejection warning
      let caughtError: Error | null = null;
      const acquirePromise = rotator.acquireKey(100).catch((e) => {
        caughtError = e;
      });

      // Advance time past timeout
      await vi.advanceTimersByTimeAsync(150);
      await acquirePromise;

      expect(caughtError).toBeInstanceOf(KeyRotatorError);
      expect((caughtError as KeyRotatorError).code).toBe('timeout');
    });

    it('should prefer keys that have been idle longest', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);

      // Use key1
      const first = await rotator.acquireKey();
      expect(first).toBe('key1');
      rotator.releaseKey(first);

      // Advance time so key1 is available again
      await vi.advanceTimersByTimeAsync(1001);

      // Use key2
      const second = await rotator.acquireKey();
      expect(second).toBe('key2');
      rotator.releaseKey(second);

      // Advance time so key2 is available again
      await vi.advanceTimersByTimeAsync(1001);

      // key1 has been idle longer, should be chosen
      const third = await rotator.acquireKey();
      expect(third).toBe('key1');
    });
  });

  describe('releaseKey', () => {
    it('should mark key as used (starts rate limit period)', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);

      const key = await rotator.acquireKey();
      rotator.releaseKey(key);

      const status = rotator.getStatus();
      // One key should be on cooldown, one should be available
      expect(status.available).toBe(1);
    });

    it('should allow re-release of unknown key without error', () => {
      const rotator = new BraveKeyRotator(['key1']);
      expect(() => rotator.releaseKey('unknown-key')).not.toThrow();
    });
  });

  describe('markRateLimited', () => {
    it('should mark a key as rate limited for specified duration', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);

      const key1 = await rotator.acquireKey();
      rotator.markRateLimited(key1, 5000); // 5 second rate limit from API

      // key1 should not be available, but key2 should be
      const key2 = await rotator.acquireKey();
      expect(key2).toBe('key2');

      rotator.releaseKey(key2);

      // After 5 seconds, key1 should be available again
      await vi.advanceTimersByTimeAsync(5001);

      const key3 = await rotator.acquireKey();
      expect(key3).toBe('key1');
    });

    it('should handle rate limit on unknown key', () => {
      const rotator = new BraveKeyRotator(['key1']);
      expect(() => rotator.markRateLimited('unknown', 1000)).not.toThrow();
    });
  });

  describe('getStatus', () => {
    it('should return correct initial status', () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);
      const status = rotator.getStatus();

      expect(status.total).toBe(2);
      expect(status.available).toBe(2);
      expect(status.keys).toHaveLength(2);
    });

    it('should reflect key availability after use', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);

      const key = await rotator.acquireKey();
      rotator.releaseKey(key);

      const status = rotator.getStatus();
      expect(status.available).toBe(1);
    });

    it('should show keys becoming available over time', async () => {
      const rotator = new BraveKeyRotator(['key1']);

      const key = await rotator.acquireKey();
      rotator.releaseKey(key);

      expect(rotator.getStatus().available).toBe(0);

      await vi.advanceTimersByTimeAsync(1001);

      expect(rotator.getStatus().available).toBe(1);
    });

    it('should include key states', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2']);

      const key = await rotator.acquireKey();
      rotator.releaseKey(key);

      const status = rotator.getStatus();
      // Keys are masked as "key1..." format
      const key1State = status.keys.find((k) => k.key.startsWith('key1'));
      const key2State = status.keys.find((k) => k.key.startsWith('key2'));

      expect(key1State?.isAvailable).toBe(false);
      expect(key2State?.isAvailable).toBe(true);
    });
  });

  describe('concurrent access', () => {
    it('should handle multiple concurrent acquires', async () => {
      const rotator = new BraveKeyRotator(['key1', 'key2', 'key3']);

      // Start 3 concurrent acquires
      const promises = [
        rotator.acquireKey(),
        rotator.acquireKey(),
        rotator.acquireKey(),
      ];

      const keys = await Promise.all(promises);

      // Should get all 3 different keys
      expect(new Set(keys).size).toBe(3);
    });

    it('should queue requests when all keys are busy', async () => {
      const rotator = new BraveKeyRotator(['key1']);

      // First acquire succeeds
      const key1 = await rotator.acquireKey();
      rotator.releaseKey(key1);

      // Start two more acquires (both need to wait)
      const promise2 = rotator.acquireKey();
      const promise3 = rotator.acquireKey();

      // Advance time to release rate limit and allow first pending request
      await vi.advanceTimersByTimeAsync(1001);

      const key2 = await promise2;
      rotator.releaseKey(key2);

      await vi.advanceTimersByTimeAsync(1001);

      const key3 = await promise3;

      expect(key1).toBe('key1');
      expect(key2).toBe('key1');
      expect(key3).toBe('key1');
    });
  });

  describe('custom RPS limit', () => {
    it('should respect custom rpsLimit of 2', async () => {
      const rotator = new BraveKeyRotator(['key1'], { rpsLimit: 2 });

      // First request should be immediate
      const key1 = await rotator.acquireKey();
      rotator.releaseKey(key1);

      // Second request should wait 500ms (1000ms / 2 RPS)
      const acquirePromise = rotator.acquireKey();

      // After 500ms it should be available
      await vi.advanceTimersByTimeAsync(501);

      const key2 = await acquirePromise;
      expect(key2).toBe('key1');
    });
  });
});
