/**
 * @fileoverview Web Cache
 *
 * In-memory cache for WebFetch results with TTL and LRU eviction.
 * Uses URL + prompt hash as cache key to support same URL with different prompts.
 */

import type { CachedFetchResult, WebCacheConfig, CacheStats } from './types.js';

const DEFAULT_TTL = 15 * 60 * 1000; // 15 minutes
const DEFAULT_MAX_ENTRIES = 100;

/**
 * Generate a cache key from URL and prompt
 */
function generateKey(url: string, prompt: string): string {
  // Simple hash: combine URL and prompt
  // In production, could use a proper hash function
  const combined = `${url}::${prompt}`;
  let hash = 0;
  for (let i = 0; i < combined.length; i++) {
    const char = combined.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash; // Convert to 32-bit integer
  }
  return `${url}::${Math.abs(hash).toString(36)}`;
}

/**
 * In-memory cache for WebFetch results
 */
export class WebCache {
  private cache: Map<string, CachedFetchResult>;
  private accessOrder: string[]; // For LRU eviction
  private ttl: number;
  private maxEntries: number;
  private hits: number;
  private misses: number;

  constructor(config: WebCacheConfig = {}) {
    this.cache = new Map();
    this.accessOrder = [];
    this.ttl = config.ttl ?? DEFAULT_TTL;
    this.maxEntries = config.maxEntries ?? DEFAULT_MAX_ENTRIES;
    this.hits = 0;
    this.misses = 0;
  }

  /**
   * Get a cached result
   *
   * @param url - The URL that was fetched
   * @param prompt - The prompt used
   * @returns Cached result or undefined
   */
  get(url: string, prompt: string): CachedFetchResult | undefined {
    const key = generateKey(url, prompt);
    const entry = this.cache.get(key);

    if (!entry) {
      this.misses++;
      return undefined;
    }

    // Check expiration
    if (Date.now() > entry.expiresAt) {
      this.cache.delete(key);
      this.removeFromAccessOrder(key);
      this.misses++;
      return undefined;
    }

    // Update access order (move to end = most recently used)
    this.updateAccessOrder(key);
    this.hits++;

    return entry;
  }

  /**
   * Store a result in the cache
   *
   * @param url - The URL that was fetched
   * @param prompt - The prompt used
   * @param result - The result to cache
   */
  set(url: string, prompt: string, result: CachedFetchResult): void {
    const key = generateKey(url, prompt);

    // Evict if at capacity
    while (this.cache.size >= this.maxEntries) {
      this.evictOldest();
    }

    // Update the result with proper timestamps
    const cachedResult: CachedFetchResult = {
      ...result,
      cachedAt: Date.now(),
      expiresAt: Date.now() + this.ttl,
    };

    // Remove from access order if exists (will be re-added at end)
    this.removeFromAccessOrder(key);

    this.cache.set(key, cachedResult);
    this.accessOrder.push(key);
  }

  /**
   * Check if a key exists and is not expired
   */
  has(url: string, prompt: string): boolean {
    const key = generateKey(url, prompt);
    const entry = this.cache.get(key);

    if (!entry) return false;

    // Check expiration
    if (Date.now() > entry.expiresAt) {
      this.cache.delete(key);
      this.removeFromAccessOrder(key);
      return false;
    }

    return true;
  }

  /**
   * Delete a specific entry
   */
  delete(url: string, prompt: string): boolean {
    const key = generateKey(url, prompt);
    const existed = this.cache.has(key);
    this.cache.delete(key);
    this.removeFromAccessOrder(key);
    return existed;
  }

  /**
   * Clear all entries and reset stats
   */
  clear(): void {
    this.cache.clear();
    this.accessOrder = [];
    this.hits = 0;
    this.misses = 0;
  }

  /**
   * Get current cache size
   */
  size(): number {
    return this.cache.size;
  }

  /**
   * Get cache statistics
   */
  getStats(): CacheStats {
    const total = this.hits + this.misses;
    return {
      size: this.cache.size,
      hits: this.hits,
      misses: this.misses,
      hitRate: total > 0 ? this.hits / total : 0,
    };
  }

  /**
   * Clean up expired entries
   */
  cleanup(): void {
    const now = Date.now();
    const keysToDelete: string[] = [];

    for (const [key, entry] of this.cache.entries()) {
      if (now > entry.expiresAt) {
        keysToDelete.push(key);
      }
    }

    for (const key of keysToDelete) {
      this.cache.delete(key);
      this.removeFromAccessOrder(key);
    }
  }

  /**
   * Evict the oldest (least recently used) entry
   */
  private evictOldest(): void {
    if (this.accessOrder.length === 0) return;

    // First try to evict expired entries
    const now = Date.now();
    for (let i = 0; i < this.accessOrder.length; i++) {
      const key = this.accessOrder[i]!;
      const entry = this.cache.get(key);
      if (!entry || now > entry.expiresAt) {
        this.cache.delete(key);
        this.accessOrder.splice(i, 1);
        return;
      }
    }

    // No expired entries, evict LRU (first in access order)
    const oldestKey = this.accessOrder.shift();
    if (oldestKey) {
      this.cache.delete(oldestKey);
    }
  }

  /**
   * Update access order - move key to end
   */
  private updateAccessOrder(key: string): void {
    const index = this.accessOrder.indexOf(key);
    if (index !== -1) {
      this.accessOrder.splice(index, 1);
    }
    this.accessOrder.push(key);
  }

  /**
   * Remove key from access order
   */
  private removeFromAccessOrder(key: string): void {
    const index = this.accessOrder.indexOf(key);
    if (index !== -1) {
      this.accessOrder.splice(index, 1);
    }
  }
}
