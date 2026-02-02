/**
 * @fileoverview Brave API Key Rotator
 *
 * Manages multiple API keys with per-key rate limiting.
 * Brave Free Plan: 1 RPS per key, 2000 requests/month.
 *
 * Features:
 * - Round-robin key selection
 * - Per-key rate limiting (default 1 RPS)
 * - Automatic waiting when all keys are busy
 * - API-triggered rate limit handling (429 responses)
 * - Concurrent request support with queuing
 */

import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('brave-key-rotator');

/**
 * Error thrown by KeyRotator operations
 */
export class KeyRotatorError extends Error {
  constructor(
    message: string,
    public readonly code: 'no_keys' | 'timeout' | 'all_exhausted'
  ) {
    super(message);
    this.name = 'KeyRotatorError';
  }
}

/**
 * Internal state for a single API key
 */
interface KeyState {
  /** The API key */
  key: string;
  /** Timestamp of last request completion */
  lastRequestTime: number;
  /** Timestamp when key becomes available again */
  availableAt: number;
}

/**
 * Public key state for status reporting
 */
export interface PublicKeyState {
  /** Masked API key (first 4 chars + ...) */
  key: string;
  /** Timestamp of last request */
  lastRequestTime: number;
  /** Whether the key is currently available */
  isAvailable: boolean;
}

/**
 * Rotator status for logging/debugging
 */
export interface RotatorStatus {
  /** Total number of keys */
  total: number;
  /** Number of currently available keys */
  available: number;
  /** State of each key */
  keys: PublicKeyState[];
}

/**
 * Configuration options for BraveKeyRotator
 */
export interface KeyRotatorConfig {
  /** Maximum requests per second per key (default: 1) */
  rpsLimit?: number;
}

/**
 * Pending request waiting for a key
 */
interface PendingRequest {
  resolve: (key: string) => void;
  reject: (error: Error) => void;
  timeoutId?: ReturnType<typeof setTimeout>;
}

/**
 * Manages multiple Brave API keys with rate limiting.
 *
 * Usage:
 * ```typescript
 * const rotator = new BraveKeyRotator(['key1', 'key2', 'key3']);
 *
 * // Acquire a key before making a request
 * const key = await rotator.acquireKey();
 * try {
 *   const response = await fetch(url, { headers: { 'X-Subscription-Token': key } });
 *   if (response.status === 429) {
 *     const retryAfter = parseInt(response.headers.get('Retry-After') || '60', 10);
 *     rotator.markRateLimited(key, retryAfter * 1000);
 *   }
 * } finally {
 *   rotator.releaseKey(key);
 * }
 * ```
 */
export class BraveKeyRotator {
  private keys: KeyState[];
  private rpsLimit: number;
  private minIntervalMs: number;
  private pendingRequests: PendingRequest[] = [];
  private checkIntervalId?: ReturnType<typeof setInterval>;
  private nextKeyIndex: number = 0;

  /**
   * Create a new key rotator.
   *
   * @param apiKeys - Array of Brave Search API keys
   * @param config - Optional configuration
   */
  constructor(apiKeys: string[], config: KeyRotatorConfig = {}) {
    // Filter out empty strings
    const validKeys = apiKeys.filter((k) => k && k.trim() !== '');

    if (validKeys.length === 0) {
      throw new KeyRotatorError('At least one API key is required', 'no_keys');
    }

    this.rpsLimit = config.rpsLimit ?? 1;
    this.minIntervalMs = 1000 / this.rpsLimit;

    // Initialize key states
    this.keys = validKeys.map((key) => ({
      key,
      lastRequestTime: 0,
      availableAt: 0,
    }));

    logger.debug('BraveKeyRotator initialized', {
      keyCount: this.keys.length,
      rpsLimit: this.rpsLimit,
    });
  }

  /**
   * Acquire an available API key.
   * Waits if all keys are rate-limited.
   *
   * @param timeoutMs - Maximum time to wait for a key (default: 30000ms)
   * @returns The API key to use
   * @throws KeyRotatorError if timeout expires
   */
  async acquireKey(timeoutMs: number = 30000): Promise<string> {
    const now = Date.now();

    // Try to find an available key immediately
    const availableKey = this.findAvailableKey(now);
    if (availableKey) {
      logger.trace('Key acquired immediately', {
        keyPrefix: availableKey.key.substring(0, 4),
      });
      return availableKey.key;
    }

    // No key available, need to wait
    logger.debug('All keys busy, waiting for availability', {
      keyCount: this.keys.length,
      timeoutMs,
    });

    return new Promise<string>((resolve, reject) => {
      const pendingRequest: PendingRequest = { resolve, reject };

      // Set up timeout
      pendingRequest.timeoutId = setTimeout(() => {
        // Remove from pending queue
        const index = this.pendingRequests.indexOf(pendingRequest);
        if (index !== -1) {
          this.pendingRequests.splice(index, 1);
        }
        reject(new KeyRotatorError('Key acquisition timeout', 'timeout'));
      }, timeoutMs);

      // Add to pending queue
      this.pendingRequests.push(pendingRequest);

      // Start checking for available keys if not already checking
      this.ensureCheckInterval();
    });
  }

  /**
   * Release a key after completing a request.
   * This marks the key as used and starts its rate limit cooldown.
   *
   * @param key - The API key that was used
   */
  releaseKey(key: string): void {
    const keyState = this.keys.find((k) => k.key === key);
    if (!keyState) {
      // Unknown key, ignore
      return;
    }

    const now = Date.now();
    keyState.lastRequestTime = now;
    keyState.availableAt = now + this.minIntervalMs;

    logger.trace('Key released', {
      keyPrefix: key.substring(0, 4),
      availableAt: keyState.availableAt,
    });

    // Check if any pending requests can be fulfilled
    this.processPendingRequests();
  }

  /**
   * Mark a key as rate-limited by the API.
   * Called when receiving a 429 response with Retry-After header.
   *
   * @param key - The API key that was rate limited
   * @param retryAfterMs - Time in milliseconds until the key can be used again
   */
  markRateLimited(key: string, retryAfterMs: number): void {
    const keyState = this.keys.find((k) => k.key === key);
    if (!keyState) {
      return;
    }

    const now = Date.now();
    keyState.availableAt = now + retryAfterMs;

    logger.warn('Key rate limited by API', {
      keyPrefix: key.substring(0, 4),
      retryAfterMs,
      availableAt: keyState.availableAt,
    });
  }

  /**
   * Get the current status of all keys.
   *
   * @returns Status object with key availability information
   */
  getStatus(): RotatorStatus {
    const now = Date.now();

    const keyStates: PublicKeyState[] = this.keys.map((k) => ({
      key: k.key.substring(0, 4) + '...',
      lastRequestTime: k.lastRequestTime,
      isAvailable: k.availableAt <= now,
    }));

    return {
      total: this.keys.length,
      available: keyStates.filter((k) => k.isAvailable).length,
      keys: keyStates,
    };
  }

  /**
   * Find an available key, preferring keys that have been idle longest.
   */
  private findAvailableKey(now: number): KeyState | null {
    // Get all available keys
    const availableKeys = this.keys.filter((k) => k.availableAt <= now);

    if (availableKeys.length === 0) {
      return null;
    }

    // Round-robin through available keys starting from nextKeyIndex
    for (let i = 0; i < this.keys.length; i++) {
      const index = (this.nextKeyIndex + i) % this.keys.length;
      const key = this.keys[index]!;
      if (key.availableAt <= now) {
        this.nextKeyIndex = (index + 1) % this.keys.length;
        return key;
      }
    }

    // Fallback: return the one that's been idle longest
    return availableKeys.sort((a, b) => a.lastRequestTime - b.lastRequestTime)[0]!;
  }

  /**
   * Ensure we have an interval checking for available keys.
   */
  private ensureCheckInterval(): void {
    if (this.checkIntervalId !== undefined) {
      return;
    }

    // Check every 50ms for available keys
    this.checkIntervalId = setInterval(() => {
      this.processPendingRequests();
    }, 50);
  }

  /**
   * Process pending requests, fulfilling any that can get a key.
   */
  private processPendingRequests(): void {
    if (this.pendingRequests.length === 0) {
      // No more pending requests, stop checking
      if (this.checkIntervalId !== undefined) {
        clearInterval(this.checkIntervalId);
        this.checkIntervalId = undefined;
      }
      return;
    }

    const now = Date.now();
    const availableKey = this.findAvailableKey(now);

    if (availableKey) {
      // Fulfill the oldest pending request
      const request = this.pendingRequests.shift()!;

      if (request.timeoutId) {
        clearTimeout(request.timeoutId);
      }

      logger.trace('Fulfilling pending request', {
        keyPrefix: availableKey.key.substring(0, 4),
        remainingPending: this.pendingRequests.length,
      });

      request.resolve(availableKey.key);
    }
  }
}
