/**
 * @fileoverview Tests for OpenAI stream handler
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

import {
  createStreamState,
  processStreamEvent,
  parseSSEStream,
  type StreamState,
} from '../stream-handler.js';
import type { ResponsesStreamEvent } from '../types.js';
import type { StreamEvent } from '@core/types/index.js';

/**
 * Collect generator output into array
 */
function collectSync(gen: Generator<StreamEvent>): StreamEvent[] {
  const events: StreamEvent[] = [];
  for (const event of gen) {
    events.push(event);
  }
  return events;
}

/**
 * Create a mock reader from SSE data lines
 */
function createMockReader(lines: string[]): ReadableStreamDefaultReader<Uint8Array> {
  const encoder = new TextEncoder();
  let index = 0;

  return {
    read: async () => {
      if (index < lines.length) {
        const data = `data: ${lines[index]}\n\n`;
        index++;
        return { done: false, value: encoder.encode(data) };
      }
      return { done: true, value: undefined };
    },
    releaseLock: vi.fn(),
    cancel: vi.fn(),
    closed: Promise.resolve(undefined),
  } as unknown as ReadableStreamDefaultReader<Uint8Array>;
}

describe('OpenAI Stream Handler', () => {
  describe('createStreamState', () => {
    it('initializes with empty values', () => {
      const state = createStreamState();

      expect(state.accumulatedText).toBe('');
      expect(state.accumulatedThinking).toBe('');
      expect(state.toolCalls.size).toBe(0);
      expect(state.inputTokens).toBe(0);
      expect(state.outputTokens).toBe(0);
      expect(state.textStarted).toBe(false);
      expect(state.thinkingStarted).toBe(false);
      expect(state.seenThinkingTexts.size).toBe(0);
    });
  });

  describe('processStreamEvent', () => {
    describe('text streaming', () => {
      it('emits text_start on first text delta', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.output_text.delta',
          delta: 'Hello',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([
          { type: 'text_start' },
          { type: 'text_delta', delta: 'Hello' },
        ]);
        expect(state.textStarted).toBe(true);
        expect(state.accumulatedText).toBe('Hello');
      });

      it('emits only text_delta on subsequent deltas', () => {
        const state = createStreamState();
        state.textStarted = true;
        state.accumulatedText = 'Hello';

        const event: ResponsesStreamEvent = {
          type: 'response.output_text.delta',
          delta: ' world',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([
          { type: 'text_delta', delta: ' world' },
        ]);
        expect(state.accumulatedText).toBe('Hello world');
      });

      it('ignores text delta with no delta value', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.output_text.delta',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toHaveLength(0);
      });
    });

    describe('tool call streaming', () => {
      it('emits toolcall_start on output_item.added with function_call', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.output_item.added',
          item: {
            type: 'function_call',
            call_id: 'call_123',
            name: 'read_file',
            arguments: '',
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([{
          type: 'toolcall_start',
          toolCallId: 'call_123',
          name: 'read_file',
        }]);
        expect(state.toolCalls.has('call_123')).toBe(true);
      });

      it('accumulates arguments delta', () => {
        const state = createStreamState();
        state.toolCalls.set('call_123', { id: 'call_123', name: 'read_file', args: '' });

        const event: ResponsesStreamEvent = {
          type: 'response.function_call_arguments.delta',
          call_id: 'call_123',
          delta: '{"path":"/test.txt"}',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([{
          type: 'toolcall_delta',
          toolCallId: 'call_123',
          argumentsDelta: '{"path":"/test.txt"}',
        }]);
        expect(state.toolCalls.get('call_123')!.args).toBe('{"path":"/test.txt"}');
      });

      it('ignores arguments delta for unknown call_id', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.function_call_arguments.delta',
          call_id: 'call_unknown',
          delta: 'data',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toHaveLength(0);
      });
    });

    describe('reasoning streaming', () => {
      it('emits thinking_start on reasoning item added', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.output_item.added',
          item: { type: 'reasoning' },
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([{ type: 'thinking_start' }]);
        expect(state.thinkingStarted).toBe(true);
      });

      it('emits thinking_delta for reasoning summary text', () => {
        const state = createStreamState();
        state.thinkingStarted = true;

        const event: ResponsesStreamEvent = {
          type: 'response.reasoning_summary_text.delta',
          delta: 'Analyzing...',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toEqual([
          { type: 'thinking_delta', delta: 'Analyzing...' },
        ]);
        expect(state.accumulatedThinking).toBe('Analyzing...');
      });

      it('deduplicates reasoning text', () => {
        const state = createStreamState();
        state.thinkingStarted = true;
        state.seenThinkingTexts.add('Already seen');

        const event: ResponsesStreamEvent = {
          type: 'response.reasoning_summary_text.delta',
          delta: 'Already seen',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toHaveLength(0);
      });

      it('handles reasoning from output_item.done summary', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.output_item.done',
          item: {
            type: 'reasoning',
            summary: [
              { type: 'summary_text', text: 'The approach is correct.' },
            ],
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events.map(e => e.type)).toEqual(['thinking_start', 'thinking_delta']);
        expect(state.accumulatedThinking).toBe('The approach is correct.');
      });

      it('skips output_item.done reasoning if already accumulated via deltas', () => {
        const state = createStreamState();
        state.accumulatedThinking = 'Already accumulated';

        const event: ResponsesStreamEvent = {
          type: 'response.output_item.done',
          item: {
            type: 'reasoning',
            summary: [{ type: 'summary_text', text: 'Different text' }],
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toHaveLength(0);
        expect(state.accumulatedThinking).toBe('Already accumulated');
      });
    });

    describe('response.completed', () => {
      it('emits text_end, done for text response', () => {
        const state = createStreamState();
        state.textStarted = true;
        state.accumulatedText = 'Hello world';

        const event: ResponsesStreamEvent = {
          type: 'response.completed',
          response: {
            id: 'resp-123',
            output: [
              {
                type: 'message',
                content: [{ type: 'output_text', text: 'Hello world' }],
              },
            ],
            usage: { input_tokens: 100, output_tokens: 50 },
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        const types = events.map(e => e.type);
        expect(types).toContain('text_end');
        expect(types).toContain('done');

        const doneEvent = events.find(e => e.type === 'done')!;
        expect(doneEvent.message.content).toEqual([
          { type: 'text', text: 'Hello world' },
        ]);
        expect(doneEvent.message.usage.inputTokens).toBe(100);
        expect(doneEvent.message.usage.outputTokens).toBe(50);
        expect(doneEvent.message.stopReason).toBe('end_turn');
      });

      it('emits toolcall_end and done with tool_use stop reason', () => {
        const state = createStreamState();
        state.toolCalls.set('call_abc', {
          id: 'call_abc',
          name: 'read_file',
          args: '{"path":"/test.txt"}',
        });

        const event: ResponsesStreamEvent = {
          type: 'response.completed',
          response: {
            id: 'resp-123',
            output: [{
              type: 'function_call',
              call_id: 'call_abc',
              name: 'read_file',
              arguments: '{"path":"/test.txt"}',
            }],
            usage: { input_tokens: 50, output_tokens: 30 },
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        const toolEndEvent = events.find(e => e.type === 'toolcall_end');
        expect(toolEndEvent).toBeDefined();
        expect(toolEndEvent!.toolCall.name).toBe('read_file');
        expect(toolEndEvent!.toolCall.arguments).toEqual({ path: '/test.txt' });

        const doneEvent = events.find(e => e.type === 'done')!;
        expect(doneEvent.message.stopReason).toBe('tool_use');
      });

      it('emits thinking_end before done when reasoning present', () => {
        const state = createStreamState();
        state.thinkingStarted = true;
        state.accumulatedThinking = 'Some reasoning';
        state.textStarted = true;
        state.accumulatedText = 'The answer';

        const event: ResponsesStreamEvent = {
          type: 'response.completed',
          response: {
            id: 'resp-123',
            output: [
              {
                type: 'message',
                content: [{ type: 'output_text', text: 'The answer' }],
              },
            ],
            usage: { input_tokens: 50, output_tokens: 30 },
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        const types = events.map(e => e.type);
        const thinkingEndIdx = types.indexOf('thinking_end');
        const doneIdx = types.indexOf('done');
        expect(thinkingEndIdx).toBeLessThan(doneIdx);

        const doneEvent = events.find(e => e.type === 'done')!;
        expect(doneEvent.message.content).toEqual([
          { type: 'thinking', thinking: 'Some reasoning' },
          { type: 'text', text: 'The answer' },
        ]);
      });

      it('handles empty response gracefully', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.completed',
        };

        const events = collectSync(processStreamEvent(event, state));

        expect(events).toHaveLength(0);
      });

      it('discovers function calls from completed response not seen in deltas', () => {
        const state = createStreamState();
        const event: ResponsesStreamEvent = {
          type: 'response.completed',
          response: {
            id: 'resp-123',
            output: [{
              type: 'function_call',
              call_id: 'call_new',
              name: 'write_file',
              arguments: '{"path":"/out.txt","content":"data"}',
            }],
            usage: { input_tokens: 50, output_tokens: 30 },
          },
        };

        const events = collectSync(processStreamEvent(event, state));

        const toolEnd = events.find(e => e.type === 'toolcall_end');
        expect(toolEnd).toBeDefined();
        expect(toolEnd!.toolCall.name).toBe('write_file');

        const doneEvent = events.find(e => e.type === 'done')!;
        expect(doneEvent.message.stopReason).toBe('tool_use');
      });
    });
  });

  describe('parseSSEStream', () => {
    it('processes complete text stream', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({ type: 'response.output_text.delta', delta: 'Hello' }),
        JSON.stringify({ type: 'response.output_text.delta', delta: ' world' }),
        JSON.stringify({
          type: 'response.completed',
          response: {
            id: 'resp-1',
            output: [{ type: 'message', content: [{ type: 'output_text', text: 'Hello world' }] }],
            usage: { input_tokens: 10, output_tokens: 5 },
          },
        }),
      ]);

      const events: StreamEvent[] = [];
      for await (const event of parseSSEStream(reader, state)) {
        events.push(event);
      }

      const types = events.map(e => e.type);
      expect(types).toContain('text_start');
      expect(types).toContain('text_delta');
      expect(types).toContain('text_end');
      expect(types).toContain('done');
    });

    it('skips unparseable SSE data', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        'not valid json',
        JSON.stringify({
          type: 'response.completed',
          response: {
            id: 'resp-1',
            output: [],
            usage: { input_tokens: 0, output_tokens: 0 },
          },
        }),
      ]);

      const events: StreamEvent[] = [];
      for await (const event of parseSSEStream(reader, state)) {
        events.push(event);
      }

      // Should still get the done event from the valid second line
      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
    });
  });
});
