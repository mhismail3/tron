/**
 * @fileoverview Idempotency middleware implementation
 *
 * Ensures that requests with the same idempotency key return
 * cached responses instead of being processed again.
 */

import type { RpcRequest, RpcResponse } from '../../../../rpc/types.js';
import type { Middleware, MiddlewareNext } from '../../../../rpc/middleware/index.js';
import type { IdempotencyOptions } from './types.js';
import { DEFAULT_IDEMPOTENT_METHODS, DEFAULT_TTL_MS } from './types.js';
import { createLogger } from '../../../../logging/index.js';

const logger = createLogger('idempotency');

/**
 * Extended RPC request with idempotency key
 */
export interface IdempotentRpcRequest extends RpcRequest {
  /** Optional idempotency key for request deduplication */
  idempotencyKey?: string;
}

/**
 * Check if a request has an idempotency key
 */
export function hasIdempotencyKey(request: RpcRequest): request is IdempotentRpcRequest {
  return 'idempotencyKey' in request && typeof (request as IdempotentRpcRequest).idempotencyKey === 'string';
}

/**
 * Create idempotency middleware
 *
 * @param options - Middleware options
 * @returns Middleware function
 */
export function createIdempotencyMiddleware(options: IdempotencyOptions): Middleware {
  const {
    cache,
    defaultTtlMs = DEFAULT_TTL_MS,
    idempotentMethods = DEFAULT_IDEMPOTENT_METHODS,
    cacheErrors = false,
  } = options;

  return async (request: RpcRequest, next: MiddlewareNext): Promise<RpcResponse> => {
    // Only process idempotent methods with an idempotency key
    if (!hasIdempotencyKey(request) || !idempotentMethods.has(request.method)) {
      return next(request);
    }

    // After the type guard, we know idempotencyKey is a string
    const key = request.idempotencyKey!;

    // Check cache for existing response
    const cached = cache.get(key);
    if (cached) {
      logger.debug('Returning cached response for idempotency key', {
        key,
        method: request.method,
        age: Date.now() - cached.createdAt.getTime(),
      });
      return cached.response;
    }

    // Process the request
    const response = await next(request);

    // Cache successful responses (and errors if configured)
    if (response.success || cacheErrors) {
      cache.set(key, response, defaultTtlMs);
      logger.debug('Cached response for idempotency key', {
        key,
        method: request.method,
        success: response.success,
        ttlMs: defaultTtlMs,
      });
    }

    return response;
  };
}
