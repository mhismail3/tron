/**
 * @fileoverview In-memory idempotency cache implementation
 *
 * Provides a simple in-memory cache for storing idempotency responses.
 * Entries automatically expire after a configurable TTL.
 */

import type { RpcResponse } from '../../../../rpc/types.js';
import type { IdempotencyCache, CachedResponse, CacheStats } from './types.js';
import { DEFAULT_TTL_MS } from './types.js';

/**
 * In-memory implementation of IdempotencyCache
 */
export class InMemoryIdempotencyCache implements IdempotencyCache {
  private cache = new Map<string, CachedResponse>();
  private hits = 0;
  private misses = 0;
  private cleanupInterval: ReturnType<typeof setInterval> | null = null;

  constructor(
    private options: {
      /** Cleanup interval in ms (default: 60 seconds) */
      cleanupIntervalMs?: number;
      /** Maximum cache size (default: 10000) */
      maxSize?: number;
    } = {}
  ) {
    const cleanupIntervalMs = options.cleanupIntervalMs ?? 60_000;
    if (cleanupIntervalMs > 0) {
      this.cleanupInterval = setInterval(() => this.cleanup(), cleanupIntervalMs);
    }
  }

  get(key: string): CachedResponse | undefined {
    const entry = this.cache.get(key);

    if (!entry) {
      this.misses++;
      return undefined;
    }

    // Check if expired
    if (entry.expiresAt < new Date()) {
      this.cache.delete(key);
      this.misses++;
      return undefined;
    }

    this.hits++;
    return entry;
  }

  set(key: string, response: RpcResponse, ttlMs: number = DEFAULT_TTL_MS): void {
    const maxSize = this.options.maxSize ?? 10_000;

    // Evict oldest entries if at capacity
    if (this.cache.size >= maxSize) {
      this.evictOldest(Math.ceil(maxSize * 0.1)); // Evict 10%
    }

    const now = new Date();
    this.cache.set(key, {
      response,
      createdAt: now,
      expiresAt: new Date(now.getTime() + ttlMs),
    });
  }

  has(key: string): boolean {
    const entry = this.cache.get(key);
    if (!entry) return false;
    if (entry.expiresAt < new Date()) {
      this.cache.delete(key);
      return false;
    }
    return true;
  }

  delete(key: string): boolean {
    return this.cache.delete(key);
  }

  cleanup(): void {
    const now = new Date();
    for (const [key, entry] of this.cache) {
      if (entry.expiresAt < now) {
        this.cache.delete(key);
      }
    }
  }

  stats(): CacheStats {
    const total = this.hits + this.misses;
    return {
      size: this.cache.size,
      hits: this.hits,
      misses: this.misses,
      hitRate: total > 0 ? (this.hits / total) * 100 : 0,
    };
  }

  /**
   * Stop the cleanup interval
   */
  destroy(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
    this.cache.clear();
  }

  /**
   * Evict the oldest entries
   */
  private evictOldest(count: number): void {
    const entries = Array.from(this.cache.entries())
      .sort((a, b) => a[1].createdAt.getTime() - b[1].createdAt.getTime())
      .slice(0, count);

    for (const [key] of entries) {
      this.cache.delete(key);
    }
  }
}

/**
 * Create a new in-memory idempotency cache
 */
export function createIdempotencyCache(
  options?: ConstructorParameters<typeof InMemoryIdempotencyCache>[0]
): IdempotencyCache {
  return new InMemoryIdempotencyCache(options);
}
