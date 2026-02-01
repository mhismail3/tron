/**
 * @fileoverview Idempotency middleware types
 *
 * Provides types for request deduplication to ensure
 * requests with the same idempotency key return cached responses.
 */

import type { RpcResponse } from '../../../../rpc/types.js';

/**
 * Cached response entry
 */
export interface CachedResponse {
  /** The cached RPC response */
  response: RpcResponse;
  /** When this entry was created */
  createdAt: Date;
  /** When this entry expires */
  expiresAt: Date;
}

/**
 * Idempotency cache interface
 */
export interface IdempotencyCache {
  /**
   * Get a cached response for a key
   * @returns The cached response or undefined if not found/expired
   */
  get(key: string): CachedResponse | undefined;

  /**
   * Store a response for a key
   * @param key - The idempotency key
   * @param response - The response to cache
   * @param ttlMs - Time to live in milliseconds
   */
  set(key: string, response: RpcResponse, ttlMs?: number): void;

  /**
   * Check if a key exists and is not expired
   */
  has(key: string): boolean;

  /**
   * Remove a key from the cache
   */
  delete(key: string): boolean;

  /**
   * Clear all expired entries
   */
  cleanup(): void;

  /**
   * Get cache statistics
   */
  stats(): CacheStats;
}

/**
 * Cache statistics
 */
export interface CacheStats {
  /** Number of entries in the cache */
  size: number;
  /** Number of cache hits */
  hits: number;
  /** Number of cache misses */
  misses: number;
  /** Hit rate as a percentage */
  hitRate: number;
}

/**
 * Idempotency middleware options
 */
export interface IdempotencyOptions {
  /** Cache instance to use */
  cache: IdempotencyCache;
  /** Default TTL in milliseconds (default: 5 minutes) */
  defaultTtlMs?: number;
  /** Methods that support idempotency */
  idempotentMethods?: Set<string>;
  /** Whether to cache error responses (default: false) */
  cacheErrors?: boolean;
}

/**
 * Default idempotent methods
 */
export const DEFAULT_IDEMPOTENT_METHODS = new Set([
  'session.create',
  'session.fork',
  'agent.prompt',
  'agent.message',
  'worktree.commit',
]);

/**
 * Default TTL: 5 minutes
 */
export const DEFAULT_TTL_MS = 5 * 60 * 1000;
