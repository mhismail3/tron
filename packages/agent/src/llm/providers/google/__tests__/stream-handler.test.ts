/**
 * @fileoverview Tests for Google SSE stream handler
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

import { createStreamState, parseSSEStream, type StreamState } from '../stream-handler.js';
import type { StreamEvent } from '@core/types/index.js';

/**
 * Helper to create a mock ReadableStreamDefaultReader from SSE data lines
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

/**
 * Collect all events from the async generator
 */
async function collectEvents(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  state: StreamState
): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const event of parseSSEStream(reader, state)) {
    events.push(event);
  }
  return events;
}

describe('Google Stream Handler', () => {
  describe('createStreamState', () => {
    it('creates fresh state with empty accumulation', () => {
      const state = createStreamState();

      expect(state.accumulatedText).toBe('');
      expect(state.accumulatedThinking).toBe('');
      expect(state.toolCalls).toEqual([]);
      expect(state.inputTokens).toBe(0);
      expect(state.outputTokens).toBe(0);
      expect(state.textStarted).toBe(false);
      expect(state.thinkingStarted).toBe(false);
      expect(state.toolCallIndex).toBe(0);
    });

    it('generates a unique prefix', () => {
      const state1 = createStreamState();
      const state2 = createStreamState();

      expect(state1.uniquePrefix).toBeTruthy();
      expect(state2.uniquePrefix).toBeTruthy();
      expect(state1.uniquePrefix).not.toBe(state2.uniquePrefix);
    });
  });

  describe('parseSSEStream', () => {
    it('emits text_start, text_delta, text_end, and done for text response', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'Hello' }] } }],
        }),
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: ' world' }] }, finishReason: 'STOP' }],
          usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const types = events.map(e => e.type);
      expect(types).toContain('text_start');
      expect(types).toContain('text_delta');
      expect(types).toContain('text_end');
      expect(types).toContain('done');

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.content).toEqual([
        { type: 'text', text: 'Hello world' },
      ]);
      expect(doneEvent.message.usage.inputTokens).toBe(10);
      expect(doneEvent.message.usage.outputTokens).toBe(5);
    });

    it('handles thinking content (thought: true)', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'Let me think...', thought: true }] } }],
        }),
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'The answer is 42' }] }, finishReason: 'STOP' }],
          usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 20, totalTokenCount: 30 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const types = events.map(e => e.type);
      expect(types).toContain('thinking_start');
      expect(types).toContain('thinking_delta');
      expect(types).toContain('thinking_end');
      expect(types).toContain('text_start');
      expect(types).toContain('text_delta');
      expect(types).toContain('done');

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.content).toEqual([
        { type: 'thinking', thinking: 'Let me think...' },
        { type: 'text', text: 'The answer is 42' },
      ]);
    });

    it('handles function calls with thoughtSignature', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{
            content: {
              parts: [{
                functionCall: { name: 'read_file', args: { path: '/test.txt' } },
                thoughtSignature: 'sig_abc123',
              }],
            },
            finishReason: 'STOP',
          }],
          usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const toolStartEvent = events.find(e => e.type === 'toolcall_start')!;
      expect(toolStartEvent.name).toBe('read_file');

      const toolEndEvent = events.find(e => e.type === 'toolcall_end')!;
      expect(toolEndEvent.toolCall.name).toBe('read_file');
      expect(toolEndEvent.toolCall.arguments).toEqual({ path: '/test.txt' });
      expect(toolEndEvent.toolCall.thoughtSignature).toBe('sig_abc123');

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.stopReason).toBe('end_turn');
    });

    it('generates unique tool call IDs using state prefix', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{
            content: {
              parts: [
                { functionCall: { name: 'tool_a', args: {} } },
                { functionCall: { name: 'tool_b', args: {} } },
              ],
            },
            finishReason: 'STOP',
          }],
          usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const toolStarts = events.filter(e => e.type === 'toolcall_start');
      expect(toolStarts).toHaveLength(2);
      expect(toolStarts[0].toolCallId).toContain(`call_${state.uniquePrefix}_0`);
      expect(toolStarts[1].toolCallId).toContain(`call_${state.uniquePrefix}_1`);
    });

    it('handles SAFETY finish reason', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{
            finishReason: 'SAFETY',
            safetyRatings: [
              { category: 'HARM_CATEGORY_HARASSMENT', probability: 'HIGH' },
              { category: 'HARM_CATEGORY_HATE_SPEECH', probability: 'NEGLIGIBLE' },
            ],
          }],
        }),
      ]);

      const events = await collectEvents(reader, state);

      const safetyEvent = events.find(e => e.type === 'safety_block');
      expect(safetyEvent).toBeDefined();
      expect(safetyEvent!.blockedCategories).toContain('HARM_CATEGORY_HARASSMENT');
      expect(safetyEvent!.blockedCategories).not.toContain('HARM_CATEGORY_HATE_SPEECH');
    });

    it('synthesizes done event when stream ends without finishReason', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'Partial response' }] } }],
        }),
      ]);

      const events = await collectEvents(reader, state);

      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent!.message.content).toEqual([
        { type: 'text', text: 'Partial response' },
      ]);
      expect(doneEvent!.message.stopReason).toBe('end_turn');
    });

    it('synthesizes done with tool_use stop reason when tool calls present', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{
            content: {
              parts: [{ functionCall: { name: 'tool_a', args: {} } }],
            },
          }],
        }),
      ]);

      const events = await collectEvents(reader, state);

      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent!.message.stopReason).toBe('tool_use');
    });

    it('handles chunks with errors', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          error: { code: 400, message: 'Bad request' },
        }),
      ]);

      await expect(collectEvents(reader, state)).rejects.toThrow('Gemini error: Bad request');
    });

    it('skips chunks with no candidate parts', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({ candidates: [{}] }),
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'Hello' }] }, finishReason: 'STOP' }],
          usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 2, totalTokenCount: 7 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const textDeltas = events.filter(e => e.type === 'text_delta');
      expect(textDeltas).toHaveLength(1);
      expect(textDeltas[0].delta).toBe('Hello');
    });

    it('tracks usage metadata', async () => {
      const state = createStreamState();
      const reader = createMockReader([
        JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'Hi' }] }, finishReason: 'STOP' }],
          usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 50, totalTokenCount: 150 },
        }),
      ]);

      const events = await collectEvents(reader, state);

      const doneEvent = events.find(e => e.type === 'done')!;
      expect(doneEvent.message.usage).toEqual({
        inputTokens: 100,
        outputTokens: 50,
        providerType: 'google',
      });
    });
  });
});
