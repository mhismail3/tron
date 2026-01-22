/**
 * @fileoverview Tests for Provider Stream Retry Utilities
 */

import { describe, it, expect, vi } from 'vitest';
import { withProviderRetry } from '../stream-retry.js';
import type { StreamEvent } from '../../../types/index.js';

describe('withProviderRetry', () => {
  describe('successful streams', () => {
    it('should pass through events from successful stream', async () => {
      const events: StreamEvent[] = [
        { type: 'start' },
        { type: 'text_start' },
        { type: 'text_delta', delta: 'Hello' },
        { type: 'text_end', text: 'Hello' },
        { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' },
      ];

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        for (const event of events) {
          yield event;
        }
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream())) {
        collected.push(event);
      }

      expect(collected).toEqual(events);
    });

    it('should handle empty stream', async () => {
      async function* mockStream(): AsyncGenerator<StreamEvent> {
        // Empty stream
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream())) {
        collected.push(event);
      }

      expect(collected).toEqual([]);
    });
  });

  describe('retry behavior', () => {
    it('should retry on retryable error before data is yielded', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        if (attempts < 3) {
          yield { type: 'start' };
          throw new Error('500 Server Error');
        }
        yield { type: 'start' };
        yield { type: 'text_start' };
        yield { type: 'text_delta', delta: 'Success' };
        yield { type: 'text_end', text: 'Success' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 3,
        baseDelayMs: 10, // Use very short delays for testing
        maxDelayMs: 50,
      })) {
        collected.push(event);
      }

      expect(attempts).toBe(3);
      // Should have retry events plus final success
      const retryEvents = collected.filter(e => e.type === 'retry');
      expect(retryEvents.length).toBe(2); // 2 retries before success
      const doneEvent = collected.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
    }, 10000);

    it('should NOT retry after data has been yielded', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        yield { type: 'start' };
        yield { type: 'text_start' };
        yield { type: 'text_delta', delta: 'Partial' };
        // Error after yielding data
        throw new Error('500 Server Error');
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), { maxRetries: 3 })) {
        collected.push(event);
      }

      expect(attempts).toBe(1); // No retry
      const errorEvent = collected.find(e => e.type === 'error');
      expect(errorEvent).toBeDefined();
    });

    it('should NOT retry on non-retryable errors', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        yield { type: 'start' };
        throw new Error('401 Authentication failed');
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), { maxRetries: 3 })) {
        collected.push(event);
      }

      expect(attempts).toBe(1); // No retry for auth errors
      const errorEvent = collected.find(e => e.type === 'error');
      expect(errorEvent).toBeDefined();
    });

    it('should exhaust retries and return error', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        yield { type: 'start' };
        throw new Error('503 Service Unavailable');
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 2,
        baseDelayMs: 10,
        maxDelayMs: 50,
      })) {
        collected.push(event);
      }

      expect(attempts).toBe(3); // Initial + 2 retries
      const errorEvent = collected.find(e => e.type === 'error');
      expect(errorEvent).toBeDefined();
    }, 10000);
  });

  describe('abort signal', () => {
    it('should abort before starting', async () => {
      const controller = new AbortController();
      controller.abort();

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        yield { type: 'start' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), { signal: controller.signal })) {
        collected.push(event);
      }

      const errorEvent = collected.find(e => e.type === 'error');
      expect(errorEvent).toBeDefined();
      expect((errorEvent as any).error.message).toContain('cancelled');
    });

    it('should abort during streaming', async () => {
      const controller = new AbortController();

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        yield { type: 'start' };
        yield { type: 'text_start' };
        // Abort happens here
        yield { type: 'text_delta', delta: 'Hello' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), { signal: controller.signal })) {
        collected.push(event);
        if (event.type === 'text_start') {
          controller.abort();
        }
      }

      const errorEvent = collected.find(e => e.type === 'error');
      expect(errorEvent).toBeDefined();
    });
  });

  describe('retry callbacks', () => {
    it('should call onRetry callback', async () => {
      const onRetry = vi.fn();
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        if (attempts < 2) {
          yield { type: 'start' };
          throw new Error('429 Rate limit');
        }
        yield { type: 'start' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 2,
        onRetry,
        baseDelayMs: 10,
        maxDelayMs: 50,
      })) {
        // consume events
      }

      expect(onRetry).toHaveBeenCalledTimes(1);
      expect(onRetry).toHaveBeenCalledWith(1, expect.any(Number), expect.objectContaining({
        category: 'rate_limit',
        isRetryable: true,
      }));
    }, 10000);

    it('should emit retry events when emitRetryEvent is true', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        if (attempts < 2) {
          yield { type: 'start' };
          throw new Error('500 Server Error');
        }
        yield { type: 'start' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 2,
        emitRetryEvent: true,
        baseDelayMs: 10,
        maxDelayMs: 50,
      })) {
        collected.push(event);
      }

      const retryEvents = collected.filter(e => e.type === 'retry');
      expect(retryEvents.length).toBe(1);
      expect((retryEvents[0] as any).attempt).toBe(1);
      expect((retryEvents[0] as any).maxRetries).toBe(2);
    }, 10000);

    it('should NOT emit retry events when emitRetryEvent is false', async () => {
      let attempts = 0;

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        if (attempts < 2) {
          yield { type: 'start' };
          throw new Error('500 Server Error');
        }
        yield { type: 'start' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      const collected: StreamEvent[] = [];
      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 2,
        emitRetryEvent: false,
        baseDelayMs: 10,
        maxDelayMs: 50,
      })) {
        collected.push(event);
      }

      const retryEvents = collected.filter(e => e.type === 'retry');
      expect(retryEvents.length).toBe(0);
    }, 10000);
  });

  describe('backoff configuration', () => {
    it('should use custom delay configuration', async () => {
      let attempts = 0;
      const delays: number[] = [];

      async function* mockStream(): AsyncGenerator<StreamEvent> {
        attempts++;
        if (attempts < 3) {
          yield { type: 'start' };
          throw new Error('500 Server Error');
        }
        yield { type: 'start' };
        yield { type: 'done', message: { role: 'assistant', content: [] }, stopReason: 'stop' };
      }

      for await (const event of withProviderRetry(() => mockStream(), {
        maxRetries: 3,
        baseDelayMs: 50,
        maxDelayMs: 200,
        jitterFactor: 0, // No jitter for predictable test
      })) {
        if (event.type === 'retry') {
          delays.push((event as any).delayMs);
        }
      }

      // First retry: 50ms * 2^0 = 50ms
      // Second retry: 50ms * 2^1 = 100ms
      expect(delays[0]).toBe(50);
      expect(delays[1]).toBe(100);
    }, 10000);
  });
});
