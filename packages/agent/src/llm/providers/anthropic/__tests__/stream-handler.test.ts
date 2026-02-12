/**
 * @fileoverview Tests for Anthropic stream handler
 */

import { describe, it, expect, vi } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
    trace: vi.fn(),
  })),
}));

vi.mock('../message-converter.js', () => ({
  convertResponse: vi.fn(),
}));

import {
  createStreamState,
  processStreamEvent,
  processAnthropicStream,
  type StreamState,
  type AnthropicMessageStream,
} from '../stream-handler.js';
import { convertResponse } from '../message-converter.js';
import type { StreamEvent } from '@core/types/index.js';

/**
 * Collect synchronous generator output into array
 */
function collectSync(gen: Generator<StreamEvent>): StreamEvent[] {
  const events: StreamEvent[] = [];
  for (const event of gen) {
    events.push(event);
  }
  return events;
}

/**
 * Collect async generator output into array
 */
async function collectAsync(gen: AsyncGenerator<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const event of gen) {
    events.push(event);
  }
  return events;
}

/**
 * Create a mock AnthropicMessageStream from raw SDK events
 */
function createMockStream(
  events: any[],
  finalMsg?: any
): AnthropicMessageStream {
  return {
    async *[Symbol.asyncIterator]() {
      for (const event of events) {
        yield event;
      }
    },
    finalMessage: vi.fn().mockResolvedValue(finalMsg ?? null),
  };
}

describe('Anthropic Stream Handler', () => {
  describe('createStreamState', () => {
    it('creates fresh state with empty accumulation', () => {
      const state = createStreamState();

      expect(state.currentBlockType).toBeNull();
      expect(state.currentToolCallId).toBeNull();
      expect(state.currentToolName).toBeNull();
      expect(state.accumulatedText).toBe('');
      expect(state.accumulatedThinking).toBe('');
      expect(state.accumulatedSignature).toBe('');
      expect(state.accumulatedArgs).toBe('');
      expect(state.inputTokens).toBe(0);
      expect(state.outputTokens).toBe(0);
      expect(state.cacheCreationTokens).toBe(0);
      expect(state.cacheReadTokens).toBe(0);
    });

    it('initializes per-TTL cache creation fields to 0', () => {
      const state = createStreamState();
      expect(state.cacheCreation5mTokens).toBe(0);
      expect(state.cacheCreation1hTokens).toBe(0);
    });
  });

  describe('processStreamEvent', () => {
    describe('message_start', () => {
      it('tracks input tokens and cache tokens from usage', () => {
        const state = createStreamState();
        const event = {
          type: 'message_start' as const,
          message: {
            usage: {
              input_tokens: 100,
              cache_creation_input_tokens: 50,
              cache_read_input_tokens: 25,
            },
          },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toHaveLength(0); // No StreamEvents emitted
        expect(state.inputTokens).toBe(100);
        expect(state.cacheCreationTokens).toBe(50);
        expect(state.cacheReadTokens).toBe(25);
      });

      it('handles message_start without usage', () => {
        const state = createStreamState();
        const event = { type: 'message_start' as const, message: {} };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toHaveLength(0);
        expect(state.inputTokens).toBe(0);
      });

      it('extracts per-TTL cache creation from cache_creation field', () => {
        const state = createStreamState();
        const event = {
          type: 'message_start' as const,
          message: {
            usage: {
              input_tokens: 100,
              cache_creation_input_tokens: 50,
              cache_read_input_tokens: 25,
              cache_creation: {
                ephemeral_5m_input_tokens: 20,
                ephemeral_1h_input_tokens: 30,
              },
            },
          },
        };

        collectSync(processStreamEvent(event as any, state));

        expect(state.cacheCreation5mTokens).toBe(20);
        expect(state.cacheCreation1hTokens).toBe(30);
      });

      it('defaults per-TTL fields to 0 when cache_creation is absent', () => {
        const state = createStreamState();
        const event = {
          type: 'message_start' as const,
          message: {
            usage: {
              input_tokens: 100,
              cache_creation_input_tokens: 50,
            },
          },
        };

        collectSync(processStreamEvent(event as any, state));

        expect(state.cacheCreation5mTokens).toBe(0);
        expect(state.cacheCreation1hTokens).toBe(0);
      });
    });

    describe('message_delta', () => {
      it('tracks output tokens', () => {
        const state = createStreamState();
        const event = {
          type: 'message_delta' as const,
          usage: { output_tokens: 42 },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toHaveLength(0);
        expect(state.outputTokens).toBe(42);
      });
    });

    describe('text blocks', () => {
      it('emits text_start on content_block_start with type text', () => {
        const state = createStreamState();
        const event = {
          type: 'content_block_start' as const,
          content_block: { type: 'text' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{ type: 'text_start' }]);
        expect(state.currentBlockType).toBe('text');
      });

      it('emits text_delta and accumulates text', () => {
        const state = createStreamState();
        state.currentBlockType = 'text';
        const event = {
          type: 'content_block_delta' as const,
          delta: { type: 'text_delta', text: 'Hello' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{ type: 'text_delta', delta: 'Hello' }]);
        expect(state.accumulatedText).toBe('Hello');
      });

      it('emits text_end with accumulated text on content_block_stop', () => {
        const state = createStreamState();
        state.currentBlockType = 'text';
        state.accumulatedText = 'Hello world';
        const event = { type: 'content_block_stop' as const };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{ type: 'text_end', text: 'Hello world' }]);
        expect(state.accumulatedText).toBe('');
        expect(state.currentBlockType).toBeNull();
      });
    });

    describe('thinking blocks', () => {
      it('emits thinking_start on content_block_start with type thinking', () => {
        const state = createStreamState();
        const event = {
          type: 'content_block_start' as const,
          content_block: { type: 'thinking' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{ type: 'thinking_start' }]);
        expect(state.currentBlockType).toBe('thinking');
      });

      it('emits thinking_delta and accumulates thinking', () => {
        const state = createStreamState();
        state.currentBlockType = 'thinking';
        const event = {
          type: 'content_block_delta' as const,
          delta: { type: 'thinking_delta', thinking: 'Analyzing...' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{ type: 'thinking_delta', delta: 'Analyzing...' }]);
        expect(state.accumulatedThinking).toBe('Analyzing...');
      });

      it('accumulates signature_delta without emitting events', () => {
        const state = createStreamState();
        state.currentBlockType = 'thinking';
        const event = {
          type: 'content_block_delta' as const,
          delta: { type: 'signature_delta', signature: 'sig_abc' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toHaveLength(0);
        expect(state.accumulatedSignature).toBe('sig_abc');
      });

      it('emits thinking_end with signature on content_block_stop', () => {
        const state = createStreamState();
        state.currentBlockType = 'thinking';
        state.accumulatedThinking = 'Let me think';
        state.accumulatedSignature = 'sig_xyz';
        const event = { type: 'content_block_stop' as const };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{
          type: 'thinking_end',
          thinking: 'Let me think',
          signature: 'sig_xyz',
        }]);
        expect(state.accumulatedThinking).toBe('');
        expect(state.accumulatedSignature).toBe('');
      });

      it('emits thinking_end without signature when none accumulated', () => {
        const state = createStreamState();
        state.currentBlockType = 'thinking';
        state.accumulatedThinking = 'Brief thought';
        const event = { type: 'content_block_stop' as const };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{
          type: 'thinking_end',
          thinking: 'Brief thought',
        }]);
      });
    });

    describe('tool_use blocks', () => {
      it('emits toolcall_start on content_block_start with type tool_use', () => {
        const state = createStreamState();
        const event = {
          type: 'content_block_start' as const,
          content_block: { type: 'tool_use', id: 'toolu_123', name: 'Read' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{
          type: 'toolcall_start',
          toolCallId: 'toolu_123',
          name: 'Read',
        }]);
        expect(state.currentBlockType).toBe('tool_use');
        expect(state.currentToolCallId).toBe('toolu_123');
        expect(state.currentToolName).toBe('Read');
      });

      it('emits toolcall_delta and accumulates arguments', () => {
        const state = createStreamState();
        state.currentBlockType = 'tool_use';
        state.currentToolCallId = 'toolu_123';
        const event = {
          type: 'content_block_delta' as const,
          delta: { type: 'input_json_delta', partial_json: '{"path":' },
        };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toEqual([{
          type: 'toolcall_delta',
          toolCallId: 'toolu_123',
          argumentsDelta: '{"path":',
        }]);
        expect(state.accumulatedArgs).toBe('{"path":');
      });

      it('emits toolcall_end with parsed arguments on content_block_stop', () => {
        const state = createStreamState();
        state.currentBlockType = 'tool_use';
        state.currentToolCallId = 'toolu_123';
        state.currentToolName = 'Read';
        state.accumulatedArgs = '{"file_path":"/test.ts"}';
        const event = { type: 'content_block_stop' as const };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events).toHaveLength(1);
        expect(events[0].type).toBe('toolcall_end');
        expect(events[0].toolCall).toEqual({
          type: 'tool_use',
          id: 'toolu_123',
          name: 'Read',
          arguments: { file_path: '/test.ts' },
        });
        expect(state.accumulatedArgs).toBe('');
        expect(state.currentToolCallId).toBeNull();
        expect(state.currentToolName).toBeNull();
      });

      it('defaults to empty object when no arguments accumulated', () => {
        const state = createStreamState();
        state.currentBlockType = 'tool_use';
        state.currentToolCallId = 'toolu_456';
        state.currentToolName = 'Bash';
        state.accumulatedArgs = '';
        const event = { type: 'content_block_stop' as const };

        const events = collectSync(processStreamEvent(event as any, state));

        expect(events[0].toolCall.arguments).toEqual({});
      });
    });
  });

  describe('processAnthropicStream', () => {
    it('processes a complete text stream with finalMessage', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [{ type: 'text', text: 'Hello world' }],
        usage: { inputTokens: 10, outputTokens: 5, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [
          { type: 'message_start', message: { usage: { input_tokens: 10 } } },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: ' world' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 5 } },
          { type: 'message_stop' },
        ],
        {
          id: 'msg_123',
          role: 'assistant',
          content: [{ type: 'text', text: 'Hello world' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 10, output_tokens: 5 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const types = events.map(e => e.type);
      expect(types).toEqual([
        'text_start',
        'text_delta',
        'text_delta',
        'text_end',
        'done',
      ]);

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.stopReason).toBe('end_turn');
    });

    it('processes thinking + text blocks', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: 'Let me analyze', signature: 'sig_abc' },
          { type: 'text', text: 'The answer' },
        ],
        usage: { inputTokens: 50, outputTokens: 30, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [
          { type: 'message_start', message: { usage: { input_tokens: 50 } } },
          { type: 'content_block_start', content_block: { type: 'thinking' } },
          { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: 'Let me analyze' } },
          { type: 'content_block_delta', delta: { type: 'signature_delta', signature: 'sig_abc' } },
          { type: 'content_block_stop' },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'The answer' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 30 } },
          { type: 'message_stop' },
        ],
        {
          id: 'msg_456',
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: 'Let me analyze', signature: 'sig_abc' },
            { type: 'text', text: 'The answer' },
          ],
          stop_reason: 'end_turn',
          usage: { input_tokens: 50, output_tokens: 30 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const types = events.map(e => e.type);
      expect(types).toEqual([
        'thinking_start',
        'thinking_delta',
        'thinking_end',
        'text_start',
        'text_delta',
        'text_end',
        'done',
      ]);

      const thinkingEnd = events.find(e => e.type === 'thinking_end')!;
      expect(thinkingEnd.thinking).toBe('Let me analyze');
      expect(thinkingEnd.signature).toBe('sig_abc');
    });

    it('processes tool_use blocks', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [
          { type: 'text', text: 'Reading file' },
          { type: 'tool_use', id: 'toolu_789', name: 'Read', arguments: { file_path: '/test.ts' } },
        ],
        usage: { inputTokens: 20, outputTokens: 15, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [
          { type: 'message_start', message: { usage: { input_tokens: 20 } } },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Reading file' } },
          { type: 'content_block_stop' },
          { type: 'content_block_start', content_block: { type: 'tool_use', id: 'toolu_789', name: 'Read' } },
          { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '{"file_path":' } },
          { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '"/test.ts"}' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 15 } },
          { type: 'message_stop' },
        ],
        {
          id: 'msg_789',
          role: 'assistant',
          content: [
            { type: 'text', text: 'Reading file' },
            { type: 'tool_use', id: 'toolu_789', name: 'Read', input: { file_path: '/test.ts' } },
          ],
          stop_reason: 'tool_use',
          usage: { input_tokens: 20, output_tokens: 15 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const types = events.map(e => e.type);
      expect(types).toEqual([
        'text_start',
        'text_delta',
        'text_end',
        'toolcall_start',
        'toolcall_delta',
        'toolcall_delta',
        'toolcall_end',
        'done',
      ]);

      const toolEnd = events.find(e => e.type === 'toolcall_end')!;
      expect(toolEnd.toolCall.name).toBe('Read');
      expect(toolEnd.toolCall.arguments).toEqual({ file_path: '/test.ts' });
    });

    it('tracks cache tokens in usage', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [{ type: 'text', text: 'Cached' }],
        usage: { inputTokens: 100, outputTokens: 10, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [
          {
            type: 'message_start',
            message: {
              usage: {
                input_tokens: 100,
                cache_creation_input_tokens: 80,
                cache_read_input_tokens: 20,
              },
            },
          },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Cached' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 10 } },
          { type: 'message_stop' },
        ],
        {
          id: 'msg_cache',
          role: 'assistant',
          content: [{ type: 'text', text: 'Cached' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 100, output_tokens: 10 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.usage.inputTokens).toBe(100);
      expect(doneEvent.message.usage.outputTokens).toBe(10);
      expect(doneEvent.message.usage.cacheCreationTokens).toBe(80);
      expect(doneEvent.message.usage.cacheReadTokens).toBe(20);
    });

    it('includes per-TTL cache creation in done event usage', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [{ type: 'text', text: 'Cached' }],
        usage: { inputTokens: 100, outputTokens: 10, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [
          {
            type: 'message_start',
            message: {
              usage: {
                input_tokens: 100,
                cache_creation_input_tokens: 80,
                cache_read_input_tokens: 20,
                cache_creation: {
                  ephemeral_5m_input_tokens: 30,
                  ephemeral_1h_input_tokens: 50,
                },
              },
            },
          },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Cached' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 10 } },
          { type: 'message_stop' },
        ],
        {
          id: 'msg_ttl',
          role: 'assistant',
          content: [{ type: 'text', text: 'Cached' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 100, output_tokens: 10 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.usage.cacheCreation5mTokens).toBe(30);
      expect(doneEvent.message.usage.cacheCreation1hTokens).toBe(50);
    });

    it('falls back to empty message when finalMessage returns null', async () => {
      const stream = createMockStream(
        [
          { type: 'message_start', message: { usage: { input_tokens: 5 } } },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hi' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 2 } },
          { type: 'message_stop' },
        ],
        null
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.role).toBe('assistant');
      expect(doneEvent.message.content).toEqual([]);
      expect(doneEvent.message.usage.inputTokens).toBe(5);
      expect(doneEvent.message.usage.outputTokens).toBe(2);
    });

    it('falls back to empty message when finalMessage throws', async () => {
      const stream = createMockStream(
        [
          { type: 'message_start', message: { usage: { input_tokens: 8 } } },
          { type: 'content_block_start', content_block: { type: 'text' } },
          { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Ok' } },
          { type: 'content_block_stop' },
          { type: 'message_delta', usage: { output_tokens: 3 } },
          { type: 'message_stop' },
        ]
      );
      vi.mocked(stream.finalMessage).mockRejectedValue(new Error('Network timeout'));

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.role).toBe('assistant');
      expect(doneEvent.message.content).toEqual([]);
      expect(doneEvent.stopReason).toBe('end_turn');
    });

    it('handles stream with no events before message_stop', async () => {
      vi.mocked(convertResponse).mockReturnValue({
        role: 'assistant',
        content: [],
        usage: { inputTokens: 0, outputTokens: 0, providerType: 'anthropic' },
      } as any);

      const stream = createMockStream(
        [{ type: 'message_stop' }],
        {
          id: 'msg_empty',
          role: 'assistant',
          content: [],
          stop_reason: 'end_turn',
          usage: { input_tokens: 0, output_tokens: 0 },
        }
      );

      const state = createStreamState();
      const events = await collectAsync(processAnthropicStream(stream, state));

      expect(events).toHaveLength(1);
      expect(events[0].type).toBe('done');
    });
  });
});
