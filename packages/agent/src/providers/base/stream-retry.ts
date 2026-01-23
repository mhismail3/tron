/**
 * @fileoverview Stream Retry Utilities for Providers
 *
 * Provides retry logic specifically designed for LLM streaming responses.
 * Can only retry if no data has been yielded yet (can't retry partial streams).
 *
 * This module wraps the general retry utilities from utils/retry.ts with
 * provider-specific handling for stream events.
 */

import type { StreamEvent } from '../../types/index.js';
import { createLogger } from '../../logging/logger.js';
import { parseError, formatError } from '../../utils/errors.js';
import {
  calculateBackoffDelay,
  extractRetryAfterFromError,
  sleepWithAbort,
  type RetryConfig,
} from '../../utils/retry.js';

const logger = createLogger('provider-retry');

// =============================================================================
// Types
// =============================================================================

export interface StreamRetryConfig extends RetryConfig {
  /**
   * Callback to emit retry events to the consumer
   * If provided, yields a retry event before waiting
   */
  emitRetryEvent?: boolean;
}

// =============================================================================
// Stream Retry Wrapper
// =============================================================================

/**
 * Wrap a provider's stream method with retry logic
 *
 * This is designed to be used by providers that don't have built-in retry.
 * It will only retry if no data has been yielded yet.
 *
 * @example
 * ```typescript
 * async *stream(context: Context, options: StreamOptions): AsyncGenerator<StreamEvent> {
 *   yield* withProviderRetry(
 *     () => this.streamInternal(context, options),
 *     this.retryConfig
 *   );
 * }
 * ```
 */
export async function* withProviderRetry(
  createStream: () => AsyncGenerator<StreamEvent>,
  config: StreamRetryConfig = {}
): AsyncGenerator<StreamEvent> {
  const {
    maxRetries = 3,
    baseDelayMs = 1000,
    maxDelayMs = 30000,
    jitterFactor = 0.2,
    onRetry,
    signal,
    emitRetryEvent = true,
  } = config;

  let attempt = 0;
  let hasYieldedData = false;

  while (attempt <= maxRetries) {
    try {
      // Check for abort before attempting
      if (signal?.aborted) {
        yield { type: 'error', error: new Error('Operation was cancelled') };
        return;
      }

      const stream = createStream();
      hasYieldedData = false;

      for await (const event of stream) {
        // Check for abort during streaming
        if (signal?.aborted) {
          yield { type: 'error', error: new Error('Operation was cancelled') };
          return;
        }

        // Track when we've yielded meaningful data
        // 'start' doesn't count as data - we can still retry after that
        if (event.type !== 'start') {
          hasYieldedData = true;
        }

        yield event;

        // If we got a done or error event, we're finished
        if (event.type === 'done' || event.type === 'error') {
          return;
        }
      }

      // Successfully completed without explicit done event
      return;
    } catch (error) {
      attempt++;
      const parsed = parseError(error);

      // Log detailed error for debugging
      logger.trace('Provider stream error - full details', {
        errorCategory: parsed.category,
        errorMessage: parsed.message,
        isRetryable: parsed.isRetryable,
        attempt,
        hasYieldedData,
        fullError: error instanceof Error ? {
          name: error.name,
          message: error.message,
          stack: error.stack,
        } : error,
      });

      // If we've already yielded data, we can't retry (partial stream)
      if (hasYieldedData) {
        logger.error('Stream error after partial data, cannot retry', {
          category: parsed.category,
          message: parsed.message,
          attempt,
        });
        const streamError = new Error(formatError(error));
        if (error instanceof Error) {
          streamError.cause = error;
        }
        yield { type: 'error', error: streamError };
        return;
      }

      // Don't retry non-retryable errors
      if (!parsed.isRetryable) {
        logger.error('Non-retryable stream error', {
          category: parsed.category,
          message: parsed.message,
        });
        const streamError = new Error(formatError(error));
        if (error instanceof Error) {
          streamError.cause = error;
        }
        yield { type: 'error', error: streamError };
        return;
      }

      // Check if we've exhausted retries
      if (attempt > maxRetries) {
        logger.error('Stream max retries exhausted', {
          category: parsed.category,
          message: parsed.message,
          attempts: attempt,
        });
        const streamError = new Error(formatError(error));
        if (error instanceof Error) {
          streamError.cause = error;
        }
        yield { type: 'error', error: streamError };
        return;
      }

      // Calculate delay with exponential backoff and jitter
      const delayMs = calculateBackoffDelay(
        attempt - 1,
        baseDelayMs,
        maxDelayMs,
        jitterFactor
      );

      // Check for retry-after header
      const retryAfter = extractRetryAfterFromError(error);
      const actualDelay = retryAfter !== null ? Math.max(delayMs, retryAfter) : delayMs;

      logger.info('Retrying stream after error', {
        category: parsed.category,
        message: parsed.message,
        attempt,
        maxRetries,
        delayMs: actualDelay,
      });

      // Emit retry event so consumers can show status
      if (emitRetryEvent) {
        yield {
          type: 'retry',
          attempt,
          maxRetries,
          delayMs: actualDelay,
          error: parsed,
        } as StreamEvent;
      }

      // Invoke callback if provided
      if (onRetry) {
        onRetry(attempt, actualDelay, parsed);
      }

      // Wait before retry
      await sleepWithAbort(actualDelay, signal);
    }
  }
}

// Helper functions (extractRetryAfterFromError, sleepWithAbort) are now
// imported from utils/retry.ts to avoid duplication
