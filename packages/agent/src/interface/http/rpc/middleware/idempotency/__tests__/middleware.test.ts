/**
 * @fileoverview Tests for idempotency middleware
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createIdempotencyMiddleware, hasIdempotencyKey } from '../middleware.js';
import { InMemoryIdempotencyCache } from '../cache.js';
import { DEFAULT_IDEMPOTENT_METHODS } from '../types.js';
import type { RpcRequest, RpcResponse } from '../../../../../rpc/types.js';

describe('createIdempotencyMiddleware', () => {
  let cache: InMemoryIdempotencyCache;

  const createRequest = (
    method: string,
    idempotencyKey?: string
  ): RpcRequest & { idempotencyKey?: string } => ({
    id: 'req-1',
    method,
    params: {},
    ...(idempotencyKey && { idempotencyKey }),
  });

  const createResponse = (success = true): RpcResponse => ({
    id: 'req-1',
    success,
    result: success ? { sessionId: 'sess-1' } : undefined,
    error: success ? undefined : { code: 'ERROR', message: 'test error' },
  });

  beforeEach(() => {
    cache = new InMemoryIdempotencyCache({ cleanupIntervalMs: 0 });
  });

  describe('hasIdempotencyKey', () => {
    it('should return true for requests with idempotency key', () => {
      const request = createRequest('session.create', 'key-1');
      expect(hasIdempotencyKey(request)).toBe(true);
    });

    it('should return false for requests without idempotency key', () => {
      const request = createRequest('session.create');
      expect(hasIdempotencyKey(request)).toBe(false);
    });
  });

  describe('middleware behavior', () => {
    it('should pass through requests without idempotency key', async () => {
      const middleware = createIdempotencyMiddleware({ cache });
      const next = vi.fn().mockResolvedValue(createResponse());

      const request = createRequest('session.create');
      const response = await middleware(request, next);

      expect(next).toHaveBeenCalledWith(request);
      expect(response.success).toBe(true);
    });

    it('should pass through requests for non-idempotent methods', async () => {
      const middleware = createIdempotencyMiddleware({ cache });
      const next = vi.fn().mockResolvedValue(createResponse());

      const request = createRequest('session.get', 'key-1'); // get is not idempotent
      const response = await middleware(request, next);

      expect(next).toHaveBeenCalledWith(request);
      expect(response.success).toBe(true);
    });

    it('should cache and return cached response for duplicate requests', async () => {
      const middleware = createIdempotencyMiddleware({ cache });
      const expectedResponse = createResponse();
      const next = vi.fn().mockResolvedValue(expectedResponse);

      const request = createRequest('session.create', 'key-1');

      // First request - should call next
      const response1 = await middleware(request, next);
      expect(next).toHaveBeenCalledTimes(1);
      expect(response1).toEqual(expectedResponse);

      // Second request with same key - should return cached
      const response2 = await middleware(request, next);
      expect(next).toHaveBeenCalledTimes(1); // Still only called once
      expect(response2).toEqual(expectedResponse);
    });

    it('should not cache error responses by default', async () => {
      const middleware = createIdempotencyMiddleware({ cache });
      const errorResponse = createResponse(false);
      const successResponse = createResponse(true);
      const next = vi
        .fn()
        .mockResolvedValueOnce(errorResponse)
        .mockResolvedValueOnce(successResponse);

      const request = createRequest('session.create', 'key-1');

      // First request - returns error, should not cache
      await middleware(request, next);

      // Second request - should call next again
      const response2 = await middleware(request, next);
      expect(next).toHaveBeenCalledTimes(2);
      expect(response2.success).toBe(true);
    });

    it('should cache error responses when configured', async () => {
      const middleware = createIdempotencyMiddleware({
        cache,
        cacheErrors: true,
      });
      const errorResponse = createResponse(false);
      const next = vi.fn().mockResolvedValue(errorResponse);

      const request = createRequest('session.create', 'key-1');

      await middleware(request, next);
      await middleware(request, next);

      expect(next).toHaveBeenCalledTimes(1); // Error was cached
    });

    it('should support custom idempotent methods', async () => {
      const customMethods = new Set(['custom.method']);
      const middleware = createIdempotencyMiddleware({
        cache,
        idempotentMethods: customMethods,
      });
      const next = vi.fn().mockResolvedValue(createResponse());

      const request = createRequest('custom.method', 'key-1');

      await middleware(request, next);
      await middleware(request, next);

      expect(next).toHaveBeenCalledTimes(1);
    });

    it('should use custom TTL', async () => {
      vi.useFakeTimers();

      const middleware = createIdempotencyMiddleware({
        cache,
        defaultTtlMs: 1000,
      });
      const next = vi.fn().mockResolvedValue(createResponse());

      const request = createRequest('session.create', 'key-1');

      await middleware(request, next);
      expect(next).toHaveBeenCalledTimes(1);

      // Advance past TTL
      vi.advanceTimersByTime(1001);

      await middleware(request, next);
      expect(next).toHaveBeenCalledTimes(2);

      vi.useRealTimers();
    });

    it('should use different cache entries for different keys', async () => {
      const middleware = createIdempotencyMiddleware({ cache });
      const response1 = { ...createResponse(), result: { sessionId: 'sess-1' } };
      const response2 = { ...createResponse(), result: { sessionId: 'sess-2' } };
      const next = vi
        .fn()
        .mockResolvedValueOnce(response1)
        .mockResolvedValueOnce(response2);

      const request1 = createRequest('session.create', 'key-1');
      const request2 = createRequest('session.create', 'key-2');

      const result1 = await middleware(request1, next);
      const result2 = await middleware(request2, next);

      expect(next).toHaveBeenCalledTimes(2);
      expect(result1.result).toEqual({ sessionId: 'sess-1' });
      expect(result2.result).toEqual({ sessionId: 'sess-2' });
    });
  });

  describe('default idempotent methods', () => {
    it.each([
      'session.create',
      'session.fork',
      'agent.prompt',
      'agent.message',
      'worktree.commit',
    ])('should include %s as idempotent method', (method) => {
      expect(DEFAULT_IDEMPOTENT_METHODS.has(method)).toBe(true);
    });
  });
});
