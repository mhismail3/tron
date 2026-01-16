/**
 * @fileoverview Tests for AgentStreamProcessor
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentStreamProcessor, createStreamProcessor } from '../../src/agent/stream-processor.js';
import { createEventEmitter } from '../../src/agent/event-emitter.js';
import type { StreamEvent, AssistantMessage, ToolCall } from '../../src/types/index.js';

describe('AgentStreamProcessor', () => {
  let processor: AgentStreamProcessor;
  let eventEmitter: ReturnType<typeof createEventEmitter>;
  let mockAbortController: AbortController;

  beforeEach(() => {
    eventEmitter = createEventEmitter();
    mockAbortController = new AbortController();

    processor = createStreamProcessor({
      eventEmitter,
      sessionId: 'sess_test',
      getAbortSignal: () => mockAbortController.signal,
    });
  });

  describe('getStreamingContent', () => {
    it('should return empty string initially', () => {
      expect(processor.getStreamingContent()).toBe('');
    });
  });

  describe('resetStreamingContent', () => {
    it('should reset streaming content', async () => {
      // Process a stream to accumulate content
      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello ' },
        { type: 'text_delta', delta: 'World' },
        { type: 'done', message: createMockMessage('Hello World'), stopReason: 'end_turn' },
      ]);

      await processor.process(stream);
      expect(processor.getStreamingContent()).toBe('Hello World');

      processor.resetStreamingContent();
      expect(processor.getStreamingContent()).toBe('');
    });
  });

  describe('process', () => {
    it('should accumulate text deltas', async () => {
      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello ' },
        { type: 'text_delta', delta: 'World!' },
        { type: 'done', message: createMockMessage('Hello World!'), stopReason: 'end_turn' },
      ]);

      const result = await processor.process(stream);

      expect(result.accumulatedText).toBe('Hello World!');
      expect(processor.getStreamingContent()).toBe('Hello World!');
    });

    it('should collect tool calls', async () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_123',
        name: 'Read',
        arguments: { file_path: '/test.txt' },
      };

      const stream = createMockStream([
        { type: 'toolcall_end', toolCall },
        { type: 'done', message: createMockMessage('', [toolCall]), stopReason: 'tool_use' },
      ]);

      const result = await processor.process(stream);

      expect(result.toolCalls).toHaveLength(1);
      expect(result.toolCalls[0]).toEqual(toolCall);
    });

    it('should emit message_update events for text deltas', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);

      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello' },
        { type: 'done', message: createMockMessage('Hello'), stopReason: 'end_turn' },
      ]);

      await processor.process(stream);

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'message_update',
          content: 'Hello',
        })
      );
    });

    it('should emit api_retry events on retry', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);

      const stream = createMockStream([
        {
          type: 'retry',
          attempt: 1,
          maxRetries: 3,
          delayMs: 1000,
          error: { category: 'rate_limit', message: 'Rate limited' },
        },
        { type: 'text_delta', delta: 'Success' },
        { type: 'done', message: createMockMessage('Success'), stopReason: 'end_turn' },
      ]);

      await processor.process(stream);

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'api_retry',
          attempt: 1,
          maxRetries: 3,
        })
      );
    });

    it('should throw on error event', async () => {
      const stream = createMockStream([
        { type: 'error', error: new Error('API Error') },
      ]);

      await expect(processor.process(stream)).rejects.toThrow('API Error');
    });

    it('should throw when no done event received', async () => {
      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello' },
      ]);

      await expect(processor.process(stream)).rejects.toThrow('No response received');
    });

    it('should throw on abort', async () => {
      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello' },
        // Simulate delay that allows abort to happen
      ]);

      mockAbortController.abort();

      await expect(processor.process(stream)).rejects.toThrow('Aborted');
    });

    it('should call onTextDelta callback', async () => {
      const onTextDelta = vi.fn();

      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello' },
        { type: 'text_delta', delta: ' World' },
        { type: 'done', message: createMockMessage('Hello World'), stopReason: 'end_turn' },
      ]);

      await processor.process(stream, { onTextDelta });

      expect(onTextDelta).toHaveBeenCalledWith('Hello');
      expect(onTextDelta).toHaveBeenCalledWith(' World');
    });

    it('should call onToolCallEnd callback', async () => {
      const onToolCallEnd = vi.fn();
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_123',
        name: 'Read',
        arguments: {},
      };

      const stream = createMockStream([
        { type: 'toolcall_end', toolCall },
        { type: 'done', message: createMockMessage(''), stopReason: 'tool_use' },
      ]);

      await processor.process(stream, { onToolCallEnd });

      expect(onToolCallEnd).toHaveBeenCalledWith(toolCall);
    });

    it('should deduplicate tool calls from final message', async () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_123',
        name: 'Read',
        arguments: {},
      };

      const stream = createMockStream([
        { type: 'toolcall_end', toolCall },
        // Final message also contains the same tool call
        { type: 'done', message: createMockMessage('', [toolCall]), stopReason: 'tool_use' },
      ]);

      const result = await processor.process(stream);

      // Should not duplicate
      expect(result.toolCalls).toHaveLength(1);
    });

    it('should rebuild empty message from accumulated data', async () => {
      const stream = createMockStream([
        { type: 'text_delta', delta: 'Hello World' },
        { type: 'done', message: createEmptyMessage(), stopReason: 'end_turn' },
      ]);

      const result = await processor.process(stream);

      expect(result.message.content).toHaveLength(1);
      expect((result.message.content[0] as { type: 'text'; text: string }).text).toBe('Hello World');
    });

    it('should return stopReason from done event', async () => {
      const stream = createMockStream([
        { type: 'done', message: createMockMessage(''), stopReason: 'max_tokens' },
      ]);

      const result = await processor.process(stream);

      expect(result.stopReason).toBe('max_tokens');
    });
  });
});

// Helper functions

function createMockStream(events: StreamEvent[]): AsyncGenerator<StreamEvent> {
  async function* generator(): AsyncGenerator<StreamEvent> {
    for (const event of events) {
      yield event;
    }
  }
  return generator();
}

function createMockMessage(text: string, toolCalls?: ToolCall[]): AssistantMessage {
  const content: AssistantMessage['content'] = [];

  if (text) {
    content.push({ type: 'text', text });
  }

  if (toolCalls) {
    content.push(...toolCalls);
  }

  return {
    role: 'assistant',
    content,
    usage: {
      inputTokens: 100,
      outputTokens: 50,
    },
    stopReason: 'end_turn',
    providerId: 'anthropic',
    model: 'claude-3-5-sonnet-20241022',
  };
}

function createEmptyMessage(): AssistantMessage {
  return {
    role: 'assistant',
    content: [],
    usage: {
      inputTokens: 100,
      outputTokens: 50,
    },
    stopReason: 'end_turn',
    providerId: 'anthropic',
    model: 'claude-3-5-sonnet-20241022',
  };
}
