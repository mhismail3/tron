/**
 * @fileoverview Provider Contract Tests
 *
 * These tests define the behavioral contracts that ALL providers must satisfy.
 * They serve as the foundation for TDD-based refactoring.
 *
 * Contract areas:
 * 1. Configuration - auth, model, options
 * 2. Streaming - text deltas, ordering, completion
 * 3. Tool calls - ID generation, argument parsing
 * 4. Token usage - input/output counts
 * 5. Message types - user/assistant/toolResult
 *
 * Note: Anthropic SDK mocking is complex because the provider creates its own
 * client instance internally. Those tests focus on configuration/type contracts.
 * Google tests mock at the fetch level which works reliably.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { Context, Message, StreamEvent, AssistantMessage, ToolCall } from '@core/types/index.js';
import { GoogleProvider, type GoogleConfig } from '../google/index.js';
import type { AnthropicConfig, StreamOptions } from '../anthropic/index.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMinimalContext(messages: Message[] = []): Context {
  return {
    messages: messages.length > 0 ? messages : [{ role: 'user', content: 'Hello' }],
  };
}

function createContextWithTools(): Context {
  return {
    messages: [{ role: 'user', content: 'Read the file at /test.ts' }],
    tools: [
      {
        name: 'Read',
        description: 'Read a file from disk',
        parameters: {
          type: 'object',
          properties: {
            file_path: { type: 'string', description: 'Path to the file' },
          },
          required: ['file_path'],
        },
      },
    ],
  };
}

async function collectEvents(stream: AsyncGenerator<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const event of stream) {
    events.push(event);
  }
  return events;
}

function findEventByType<T extends StreamEvent['type']>(
  events: StreamEvent[],
  type: T
): Extract<StreamEvent, { type: T }> | undefined {
  return events.find(e => e.type === type) as Extract<StreamEvent, { type: T }> | undefined;
}

// =============================================================================
// Anthropic Provider Contract (Configuration/Types)
// =============================================================================

describe('Anthropic Provider Contract', () => {
  describe('Configuration Contract', () => {
    it('should accept API key authentication config', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'sk-ant-test' },
      };

      expect(config.auth.type).toBe('api_key');
      expect(config.model).toBe('claude-sonnet-4-20250514');
    });

    it('should accept OAuth authentication config', () => {
      const config: AnthropicConfig = {
        model: 'claude-opus-4-5-20251101',
        auth: {
          type: 'oauth',
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
          expiresAt: Date.now() + 3600000,
        },
      };

      expect(config.auth.type).toBe('oauth');
    });

    it('should accept optional parameters', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'test' },
        maxTokens: 8192,
        temperature: 0.7,
        thinkingBudget: 16000,
        baseURL: 'https://custom.api.anthropic.com',
        retry: {
          maxRetries: 5,
          baseDelayMs: 500,
          maxDelayMs: 30000,
          jitterFactor: 0.1,
        },
      };

      expect(config.maxTokens).toBe(8192);
      expect(config.temperature).toBe(0.7);
      expect(config.thinkingBudget).toBe(16000);
      expect(config.retry?.maxRetries).toBe(5);
    });
  });

  describe('Model Constants Contract', () => {
    it('should define Claude model IDs', async () => {
      const { CLAUDE_MODELS } = await import('../anthropic/index.js');

      expect(CLAUDE_MODELS['claude-opus-4-5-20251101']).toBeDefined();
      expect(CLAUDE_MODELS['claude-sonnet-4-5-20250929']).toBeDefined();
      expect(CLAUDE_MODELS['claude-haiku-4-5-20251001']).toBeDefined();
    });

    it('should include model capabilities', async () => {
      const { CLAUDE_MODELS } = await import('../anthropic/index.js');

      const opus = CLAUDE_MODELS['claude-opus-4-5-20251101'];
      expect(opus.name).toBeDefined();
      expect(opus.contextWindow).toBeGreaterThan(0);
      expect(opus.maxOutput).toBeGreaterThan(0);
      expect(opus.supportsThinking).toBe(true);
      expect(opus.inputCostPer1k).toBeDefined();
      expect(opus.outputCostPer1k).toBeDefined();
    });

    it('should have DEFAULT_MODEL export', async () => {
      const { DEFAULT_MODEL } = await import('../anthropic/index.js');
      expect(DEFAULT_MODEL).toBeDefined();
      expect(typeof DEFAULT_MODEL).toBe('string');
    });
  });

  describe('Stream Options Contract', () => {
    it('should define streaming options type', () => {
      const options: StreamOptions = {
        maxTokens: 4096,
        temperature: 0.5,
        enableThinking: true,
        thinkingBudget: 8000,
        stopSequences: ['END', 'STOP'],
      };

      expect(options.enableThinking).toBe(true);
      expect(options.thinkingBudget).toBe(8000);
    });
  });
});

// =============================================================================
// Google Provider Contract (Full Streaming Tests)
// =============================================================================

describe('Google Provider Contract', () => {
  const originalFetch = global.fetch;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  function createProvider(config?: Partial<GoogleConfig>): GoogleProvider {
    return new GoogleProvider({
      model: 'gemini-2.5-pro',
      auth: { type: 'api_key', apiKey: 'test-key' },
      ...config,
    });
  }

  function mockStreamResponse(chunks: string[]) {
    const encoder = new TextEncoder();
    let chunkIndex = 0;

    const mockReadableStream = new ReadableStream({
      pull(controller) {
        if (chunkIndex < chunks.length) {
          controller.enqueue(encoder.encode(chunks[chunkIndex]));
          chunkIndex++;
        } else {
          controller.close();
        }
      },
    });

    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      body: mockReadableStream,
    });
  }

  describe('Stream Contract', () => {
    it('should yield start event first', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      expect(events.length).toBeGreaterThan(0);
      expect(events[0].type).toBe('start');
    });

    it('should yield done event last with message', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello world"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const doneEvent = findEventByType(events, 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent!.message).toBeDefined();
      expect(doneEvent!.message.role).toBe('assistant');
    });

    it('should stream text deltas', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const textDeltas = events
        .filter((e): e is Extract<StreamEvent, { type: 'text_delta' }> => e.type === 'text_delta')
        .map(e => e.delta);

      expect(textDeltas).toEqual(['Hello', ' world']);
    });
  });

  describe('Tool Call Contract', () => {
    it('should emit toolcall events for function calls', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"Read","args":{"file_path":"/test.ts"}}}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createContextWithTools()));

      const toolCallStart = findEventByType(events, 'toolcall_start');
      expect(toolCallStart).toBeDefined();
      expect(toolCallStart!.name).toBe('Read');
    });

    it('should include tool calls in done message', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"Read","args":{"file_path":"/test.ts"}}}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createContextWithTools()));

      const doneEvent = findEventByType(events, 'done');
      expect(doneEvent).toBeDefined();

      const toolCalls = doneEvent!.message.content.filter(
        (c): c is ToolCall => c.type === 'tool_use'
      );
      expect(toolCalls.length).toBe(1);
      expect(toolCalls[0].name).toBe('Read');
      expect(toolCalls[0].arguments).toEqual({ file_path: '/test.ts' });
    });
  });

  describe('Token Usage Contract', () => {
    it('should report input and output tokens', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"text":"Response"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":50,"totalTokenCount":150}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const doneEvent = findEventByType(events, 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent!.message.usage).toBeDefined();
      expect(doneEvent!.message.usage!.inputTokens).toBe(100);
      expect(doneEvent!.message.usage!.outputTokens).toBe(50);
    });
  });

  describe('Thinking Mode Contract (Gemini 3)', () => {
    it('should emit thinking events for thought content', async () => {
      const provider = createProvider({ model: 'gemini-3-pro-preview', thinkingLevel: 'high' });

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Let me think..."}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":"The answer is 42"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":10,"totalTokenCount":20}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const eventTypes = events.map(e => e.type);
      expect(eventTypes).toContain('thinking_start');
      expect(eventTypes).toContain('thinking_delta');
      expect(eventTypes).toContain('thinking_end');
    });

    it('should include thinking content in done message', async () => {
      const provider = createProvider({ model: 'gemini-3-pro-preview', thinkingLevel: 'high' });

      mockStreamResponse([
        'data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Deep analysis..."}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":"Final answer"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":15,"totalTokenCount":25}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const doneEvent = findEventByType(events, 'done');
      expect(doneEvent).toBeDefined();

      const thinkingContent = doneEvent!.message.content.find(
        (c): c is { type: 'thinking'; thinking: string } => c.type === 'thinking'
      );
      expect(thinkingContent).toBeDefined();
      expect(thinkingContent!.thinking).toBe('Deep analysis...');
    });
  });

  describe('Safety Handling Contract', () => {
    it('should emit safety_block event on SAFETY finish reason', async () => {
      const provider = createProvider();

      mockStreamResponse([
        'data: {"candidates":[{"finishReason":"SAFETY","safetyRatings":[{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","probability":"HIGH"}]}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0,"totalTokenCount":10}}\n\n',
      ]);

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const safetyEvent = events.find(e => e.type === 'safety_block');
      expect(safetyEvent).toBeDefined();
    });
  });

  describe('Error Handling Contract', () => {
    it('should emit error event on API error', async () => {
      const provider = createProvider();

      global.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        text: () => Promise.resolve('Internal Server Error'),
      });

      const events = await collectEvents(provider.stream(createMinimalContext()));

      const errorEvent = findEventByType(events, 'error');
      expect(errorEvent).toBeDefined();
    });
  });

  describe('Model Property', () => {
    it('should expose the configured model', () => {
      const provider = createProvider({ model: 'gemini-3-pro-preview' });
      expect(provider.model).toBe('gemini-3-pro-preview');
    });

    it('should expose provider id', () => {
      const provider = createProvider();
      expect(provider.id).toBe('google');
    });
  });
});

// =============================================================================
// Cross-Provider Contract Tests (Type/Structure)
// =============================================================================

describe('Cross-Provider Contract', () => {
  describe('Message Role Handling', () => {
    it('should accept user messages with string content', () => {
      const message: Message = { role: 'user', content: 'Hello' };
      expect(message.role).toBe('user');
      expect(message.content).toBe('Hello');
    });

    it('should accept user messages with array content', () => {
      const message: Message = {
        role: 'user',
        content: [{ type: 'text', text: 'Hello' }],
      };
      expect(Array.isArray(message.content)).toBe(true);
    });

    it('should accept assistant messages with content array', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Response' },
          { type: 'tool_use', id: 'tc_1', name: 'Test', arguments: {} },
        ],
      };
      expect(message.content.length).toBe(2);
    });

    it('should accept toolResult messages', () => {
      const message: Message = {
        role: 'toolResult',
        content: 'Tool output',
        toolCallId: 'tc_1',
      };
      expect(message.role).toBe('toolResult');
      expect(message.toolCallId).toBe('tc_1');
    });
  });

  describe('Stream Event Types', () => {
    it('should define all required event types', () => {
      const eventTypes = [
        'start', 'text_start', 'text_delta', 'text_end',
        'thinking_start', 'thinking_delta', 'thinking_end',
        'toolcall_start', 'toolcall_delta', 'toolcall_end',
        'done', 'error',
      ];

      const mockEvent: StreamEvent = { type: 'start' };
      expect(eventTypes.includes(mockEvent.type)).toBe(true);
    });
  });

  describe('AssistantMessage Structure', () => {
    it('should have required fields', () => {
      const message: AssistantMessage = {
        role: 'assistant',
        content: [{ type: 'text', text: 'Test' }],
      };
      expect(message.role).toBe('assistant');
      expect(message.content).toBeDefined();
    });

    it('should support optional usage field', () => {
      const message: AssistantMessage = {
        role: 'assistant',
        content: [],
        usage: { inputTokens: 100, outputTokens: 50 },
      };
      expect(message.usage!.inputTokens).toBe(100);
    });

    it('should support optional stopReason field', () => {
      const message: AssistantMessage = {
        role: 'assistant',
        content: [],
        stopReason: 'end_turn',
      };
      expect(message.stopReason).toBe('end_turn');
    });
  });
});
