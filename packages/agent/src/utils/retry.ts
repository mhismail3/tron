/**
 * @fileoverview Retry Utilities
 *
 * Provides robust retry logic with exponential backoff and jitter.
 * Handles rate limits, network errors, and transient failures.
 */

import { createLogger } from '../logging/logger.js';
import { parseError, type ParsedError } from './errors.js';

const logger = createLogger('retry');

// =============================================================================
// Types
// =============================================================================

export interface RetryConfig {
  /** Maximum number of retry attempts (default: 5) */
  maxRetries?: number;
  /** Base delay in milliseconds for exponential backoff (default: 1000ms) */
  baseDelayMs?: number;
  /** Maximum delay between retries in milliseconds (default: 60000ms) */
  maxDelayMs?: number;
  /** Jitter factor 0-1 to randomize delays (default: 0.2) */
  jitterFactor?: number;
  /** Callback invoked before each retry attempt */
  onRetry?: (attempt: number, delay: number, error: ParsedError) => void;
  /** AbortSignal to cancel retry loop */
  signal?: AbortSignal;
}

export interface RetryResult<T> {
  success: boolean;
  value?: T;
  error?: ParsedError;
  attempts: number;
  totalDelayMs: number;
}

// =============================================================================
// Constants
// =============================================================================

const DEFAULT_CONFIG: Required<Omit<RetryConfig, 'onRetry' | 'signal'>> = {
  maxRetries: 5,
  baseDelayMs: 1000,
  maxDelayMs: 60000,
  jitterFactor: 0.2,
};

// =============================================================================
// Retry Logic
// =============================================================================

/**
 * Calculate exponential backoff delay with jitter
 *
 * Uses the formula: min(maxDelay, baseDelay * 2^attempt) * (1 + random * jitter)
 * This prevents thundering herd problems and spreads out retry attempts.
 */
export function calculateBackoffDelay(
  attempt: number,
  baseDelayMs: number,
  maxDelayMs: number,
  jitterFactor: number
): number {
  // Exponential backoff: 1s, 2s, 4s, 8s, 16s, ...
  const exponentialDelay = baseDelayMs * Math.pow(2, attempt);

  // Cap at max delay
  const cappedDelay = Math.min(exponentialDelay, maxDelayMs);

  // Add jitter to prevent synchronized retries
  const jitter = 1 + (Math.random() * 2 - 1) * jitterFactor;

  return Math.round(cappedDelay * jitter);
}

/**
 * Check if an error should trigger a retry
 */
export function shouldRetry(parsed: ParsedError): boolean {
  return parsed.isRetryable;
}

/**
 * Parse retry-after header value
 * Can be either seconds or an HTTP date
 */
export function parseRetryAfterHeader(value: string | undefined): number | null {
  if (!value) return null;

  // Try parsing as number of seconds
  const seconds = parseInt(value, 10);
  if (!isNaN(seconds)) {
    return seconds * 1000; // Convert to milliseconds
  }

  // Try parsing as HTTP date
  const date = new Date(value);
  if (!isNaN(date.getTime())) {
    const delayMs = date.getTime() - Date.now();
    return delayMs > 0 ? delayMs : 0;
  }

  return null;
}

/**
 * Sleep for a specified duration, respecting abort signal
 */
export async function sleepWithAbort(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error('Aborted'));
      return;
    }

    const timeout = setTimeout(resolve, ms);

    if (signal) {
      const onAbort = () => {
        clearTimeout(timeout);
        reject(new Error('Aborted'));
      };
      signal.addEventListener('abort', onAbort, { once: true });
    }
  });
}

/**
 * Execute an async operation with retry logic
 *
 * Features:
 * - Exponential backoff with configurable base delay
 * - Jitter to prevent thundering herd
 * - Respects retry-after headers when available
 * - Only retries on retryable errors (rate limits, network, server errors)
 * - Supports abort signal for cancellation
 */
export async function withRetry<T>(
  operation: () => Promise<T>,
  config: RetryConfig = {}
): Promise<RetryResult<T>> {
  const {
    maxRetries = DEFAULT_CONFIG.maxRetries,
    baseDelayMs = DEFAULT_CONFIG.baseDelayMs,
    maxDelayMs = DEFAULT_CONFIG.maxDelayMs,
    jitterFactor = DEFAULT_CONFIG.jitterFactor,
    onRetry,
    signal,
  } = config;

  let attempts = 0;
  let totalDelayMs = 0;
  let lastError: ParsedError | undefined;

  while (attempts <= maxRetries) {
    try {
      // Check for abort before attempting
      if (signal?.aborted) {
        return {
          success: false,
          error: {
            category: 'unknown',
            message: 'Operation was cancelled',
            isRetryable: false,
          },
          attempts,
          totalDelayMs,
        };
      }

      const value = await operation();

      // Log successful retry when there were previous failures
      if (attempts > 0) {
        logger.trace('Retry succeeded', {
          attempts: attempts + 1,
          totalDelayMs,
          lastErrorCategory: lastError?.category,
        });
      }

      return {
        success: true,
        value,
        attempts: attempts + 1,
        totalDelayMs,
      };
    } catch (error) {
      attempts++;
      const parsed = parseError(error);
      lastError = parsed;

      // Don't retry non-retryable errors
      if (!shouldRetry(parsed)) {
        logger.debug('Non-retryable error, not retrying', {
          category: parsed.category,
          message: parsed.message,
          attempts,
        });
        return {
          success: false,
          error: parsed,
          attempts,
          totalDelayMs,
        };
      }

      // Check if we've exhausted retries
      if (attempts > maxRetries) {
        logger.warn('Max retries exhausted', {
          category: parsed.category,
          message: parsed.message,
          attempts,
          totalDelayMs,
        });
        return {
          success: false,
          error: parsed,
          attempts,
          totalDelayMs,
        };
      }

      // Calculate delay
      let delayMs = calculateBackoffDelay(attempts - 1, baseDelayMs, maxDelayMs, jitterFactor);

      // Check for retry-after header in error
      const retryAfter = extractRetryAfterFromError(error);
      if (retryAfter !== null) {
        delayMs = Math.max(delayMs, retryAfter);
      }

      logger.info('Retrying after error', {
        category: parsed.category,
        message: parsed.message,
        attempt: attempts,
        maxRetries,
        delayMs,
      });

      // Invoke callback
      if (onRetry) {
        onRetry(attempts, delayMs, parsed);
      }

      // Wait before retry
      try {
        await sleepWithAbort(delayMs, signal);
        totalDelayMs += delayMs;
      } catch {
        // Aborted during sleep
        return {
          success: false,
          error: {
            category: 'unknown',
            message: 'Operation was cancelled during retry wait',
            isRetryable: false,
          },
          attempts,
          totalDelayMs,
        };
      }
    }
  }

  // Should not reach here, but return last error if we do
  return {
    success: false,
    error: lastError ?? {
      category: 'unknown',
      message: 'Unknown error during retry',
      isRetryable: false,
    },
    attempts,
    totalDelayMs,
  };
}

/**
 * Extract retry-after value from an error object
 *
 * Looks for retry-after header in error.headers or error.response.headers.
 * Returns the delay in milliseconds, or null if not found.
 */
export function extractRetryAfterFromError(error: unknown): number | null {
  if (!error || typeof error !== 'object') return null;

  // Check for headers in various locations
  const errorObj = error as {
    headers?: Record<string, string>;
    response?: { headers?: Record<string, string> };
  };

  const headers = errorObj.headers ?? errorObj.response?.headers;
  if (!headers) return null;

  // Look for retry-after header (case-insensitive)
  const retryAfterKey = Object.keys(headers).find(
    (k) => k.toLowerCase() === 'retry-after'
  );
  if (!retryAfterKey) return null;

  return parseRetryAfterHeader(headers[retryAfterKey]);
}

/**
 * Create a retrying async generator that wraps another async generator
 *
 * This is specifically designed for streaming responses where we want to
 * retry the entire stream if an error occurs before we've received any data.
 */
export async function* withStreamRetry<T>(
  createStream: () => AsyncGenerator<T>,
  config: RetryConfig = {}
): AsyncGenerator<T> {
  const {
    maxRetries = DEFAULT_CONFIG.maxRetries,
    baseDelayMs = DEFAULT_CONFIG.baseDelayMs,
    maxDelayMs = DEFAULT_CONFIG.maxDelayMs,
    jitterFactor = DEFAULT_CONFIG.jitterFactor,
    onRetry,
    signal,
  } = config;

  let attempts = 0;
  let hasYieldedData = false;

  while (attempts <= maxRetries) {
    try {
      if (signal?.aborted) {
        throw new Error('Operation was cancelled');
      }

      const stream = createStream();
      hasYieldedData = false;

      for await (const item of stream) {
        if (signal?.aborted) {
          throw new Error('Operation was cancelled');
        }
        hasYieldedData = true;
        yield item;
      }

      // Log successful retry when there were previous failures
      if (attempts > 0) {
        logger.trace('Stream retry succeeded', {
          attempts: attempts + 1,
        });
      }

      // Successfully completed
      return;
    } catch (error) {
      attempts++;
      const parsed = parseError(error);

      // If we've already yielded data, we can't retry (partial response)
      // Just re-throw to let caller handle it
      if (hasYieldedData) {
        logger.warn('Error after partial stream data, cannot retry', {
          category: parsed.category,
          message: parsed.message,
        });
        throw error;
      }

      // Don't retry non-retryable errors
      if (!shouldRetry(parsed)) {
        throw error;
      }

      // Check if we've exhausted retries
      if (attempts > maxRetries) {
        logger.warn('Stream max retries exhausted', {
          category: parsed.category,
          message: parsed.message,
          attempts,
        });
        throw error;
      }

      // Calculate delay
      let delayMs = calculateBackoffDelay(attempts - 1, baseDelayMs, maxDelayMs, jitterFactor);

      // Check for retry-after header
      const retryAfter = extractRetryAfterFromError(error);
      if (retryAfter !== null) {
        delayMs = Math.max(delayMs, retryAfter);
      }

      logger.info('Retrying stream after error', {
        category: parsed.category,
        message: parsed.message,
        attempt: attempts,
        maxRetries,
        delayMs,
      });

      if (onRetry) {
        onRetry(attempts, delayMs, parsed);
      }

      try {
        await sleepWithAbort(delayMs, signal);
      } catch {
        throw new Error('Operation was cancelled during retry wait');
      }
    }
  }
}
