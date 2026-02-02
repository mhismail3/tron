/**
 * @fileoverview Tests for token expiration utilities
 *
 * TDD: Tests for token expiration state management
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createTokenExpiration, type TokenExpirationState } from '../token-expiration.js';

describe('TokenExpirationState', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('createTokenExpiration', () => {
    it('calculates expiresAtMs correctly with buffer', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(3600, 300); // 1hr - 5min buffer
      expect(state.expiresAtMs).toBe(now + (3600 - 300) * 1000);
    });

    it('calculates expiresAtMs correctly with zero buffer', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(3600, 0);
      expect(state.expiresAtMs).toBe(now + 3600 * 1000);
    });

    it('isExpired returns false before expiration', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(3600, 0);
      expect(state.isExpired()).toBe(false);
    });

    it('isExpired returns false at boundary', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(100, 0);
      // Move to 1ms before expiration
      vi.setSystemTime(now + 100 * 1000 - 1);
      expect(state.isExpired()).toBe(false);
    });

    it('isExpired returns true at exact expiration time', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(100, 0);
      vi.setSystemTime(now + 100 * 1000);
      expect(state.isExpired()).toBe(true);
    });

    it('isExpired returns true after expiration', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(100, 0);
      vi.setSystemTime(now + 101 * 1000);
      expect(state.isExpired()).toBe(true);
    });

    it('needsRefresh respects additional buffer', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(100, 0);
      // Move to 20 seconds before expiration
      vi.setSystemTime(now + 80 * 1000);
      expect(state.needsRefresh(30000)).toBe(true); // 30s buffer - should need refresh
      expect(state.needsRefresh(10000)).toBe(false); // 10s buffer - still ok
    });

    it('needsRefresh returns true when already expired', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      const state = createTokenExpiration(100, 0);
      vi.setSystemTime(now + 200 * 1000); // Way past expiration
      expect(state.needsRefresh(0)).toBe(true);
    });

    it('works with initial buffer applied', () => {
      const now = Date.now();
      vi.setSystemTime(now);
      // Token expires in 3600s, but we apply 300s buffer at creation
      const state = createTokenExpiration(3600, 300);

      // The effective expiration is 3300s from now
      vi.setSystemTime(now + 3299 * 1000);
      expect(state.isExpired()).toBe(false);

      vi.setSystemTime(now + 3300 * 1000);
      expect(state.isExpired()).toBe(true);
    });
  });
});
