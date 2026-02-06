/**
 * @fileoverview Tests for OpenAI Provider
 *
 * Comprehensive tests for the OpenAI provider implementation including:
 * - Configuration and initialization
 * - Model registry
 * - Streaming interface (text, tool calls, reasoning)
 * - Reasoning/thinking event handling
 * - Error handling
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  OpenAIProvider,
  OPENAI_MODELS,
  type OpenAIConfig,
  type OpenAIOAuth,
} from '../openai/index.js';
import type { StreamEvent } from '@core/types/index.js';

// Create a valid mock OAuth config
function createMockAuth(): OpenAIOAuth {
  // Create a mock JWT token with required claims
  const mockPayload = {
    'https://api.openai.com/auth': {
      chatgpt_account_id: 'test-account-123',
    },
    exp: Math.floor(Date.now() / 1000) + 3600, // 1 hour from now
  };
  const encodedPayload = Buffer.from(JSON.stringify(mockPayload)).toString('base64');
  const mockToken = `header.${encodedPayload}.signature`;

  return {
    type: 'oauth',
    accessToken: mockToken,
    refreshToken: 'mock-refresh-token',
    expiresAt: Date.now() + 3600000, // 1 hour from now
  };
}

// Helper to create mock SSE stream
function createMockStream(mockData: string[]) {
  const encoder = new TextEncoder();
  let dataIndex = 0;

  return new ReadableStream({
    pull(controller) {
      if (dataIndex < mockData.length) {
        controller.enqueue(encoder.encode(mockData[dataIndex]));
        dataIndex++;
      } else {
        controller.close();
      }
    },
  });
}

describe('OpenAI Provider', () => {
  const originalFetch = global.fetch;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  describe('Configuration', () => {
    it('should accept valid configuration', () => {
      const config: OpenAIConfig = {
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
      };

      const provider = new OpenAIProvider(config);
      expect(provider.id).toBe('openai');
    });

    it('should expose model property', () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
      });

      expect(provider.model).toBe('gpt-5.2-codex');
    });

    it('should support reasoning effort setting', () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        reasoningEffort: 'high',
      });

      expect(provider).toBeDefined();
    });

    it('should include summary parameter in reasoning config', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        reasoningEffort: 'xhigh',
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      for await (const _ of provider.stream(context)) {
        // consume stream
      }

      // Verify the fetch call included reasoning with summary parameter
      expect(global.fetch).toHaveBeenCalled();
      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);

      // The reasoning config MUST include summary: 'detailed' to get reasoning summaries
      // Note: gpt-5.2-codex only supports 'detailed', not 'concise'
      expect(requestBody.reasoning).toBeDefined();
      expect(requestBody.reasoning.effort).toBe('xhigh');
      expect(requestBody.reasoning.summary).toBe('detailed');
    });
  });

  describe('Model Registry', () => {
    it('should define GPT-5.3 Codex model with correct values', () => {
      const model = OPENAI_MODELS['gpt-5.3-codex'];
      expect(model).toBeDefined();
      expect(model.contextWindow).toBe(272000);
      expect(model.maxOutput).toBe(128000);
      expect(model.tier).toBe('flagship');
      expect(model.inputCostPerMillion).toBe(1.75);
      expect(model.outputCostPerMillion).toBe(14);
      expect(model.cacheReadCostPerMillion).toBe(0.175);
      expect(model.recommended).toBe(true);
    });

    it('should define GPT-5.2 Codex model', () => {
      expect(OPENAI_MODELS['gpt-5.2-codex']).toBeDefined();
      expect(OPENAI_MODELS['gpt-5.2-codex'].contextWindow).toBe(192000);
    });

    it('should define GPT-5.1 Codex Max model', () => {
      expect(OPENAI_MODELS['gpt-5.1-codex-max']).toBeDefined();
      expect(OPENAI_MODELS['gpt-5.1-codex-max'].supportsReasoning).toBe(true);
    });

    it('should define GPT-5.1 Codex Mini model', () => {
      expect(OPENAI_MODELS['gpt-5.1-codex-mini']).toBeDefined();
    });

    it('should indicate reasoning support for all models', () => {
      for (const [, model] of Object.entries(OPENAI_MODELS)) {
        expect(model.supportsReasoning).toBe(true);
      }
    });

    it('should have recommended field for all models', () => {
      for (const [, model] of Object.entries(OPENAI_MODELS)) {
        expect(typeof model.recommended).toBe('boolean');
      }
    });

    it('should have cacheReadCostPerMillion for all models', () => {
      for (const [, model] of Object.entries(OPENAI_MODELS)) {
        expect(typeof model.cacheReadCostPerMillion).toBe('number');
      }
    });
  });

  describe('Reasoning Events', () => {
    it('should emit thinking_start when reasoning_summary_part.added received', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      expect(events.map(e => e.type)).toContain('thinking_start');
    });

    it('should emit thinking_delta for reasoning_summary_text.delta', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"**Analyzing the code...**","summary_index":0}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      const thinkingDelta = events.find(e => e.type === 'thinking_delta');
      expect(thinkingDelta).toBeDefined();
      expect((thinkingDelta as any).delta).toBe('**Analyzing the code...**');
    });

    it('should emit thinking_end with accumulated text on response.completed', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"Step 1: ","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"Analyze input","summary_index":0}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Step 1: Analyze input"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      const thinkingEnd = events.find(e => e.type === 'thinking_end');
      expect(thinkingEnd).toBeDefined();
      expect((thinkingEnd as any).thinking).toBe('Step 1: Analyze input');
    });

    it('should handle reasoning item in response.output_item.added', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.output_item.added","item":{"type":"reasoning","summary":[]}}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      expect(events.map(e => e.type)).toContain('thinking_start');
    });
  });

  describe('Mixed Content Streaming', () => {
    it('should emit reasoning before text in correct order', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        // Reasoning first
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"Thinking...","summary_index":0}\n\n',
        // Then text
        'data: {"type":"response.output_text.delta","delta":"Here is my answer"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Thinking..."}]},{"type":"message","content":[{"type":"output_text","text":"Here is my answer"}]}],"usage":{"input_tokens":10,"output_tokens":15}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      const eventTypes = events.map(e => e.type);

      // Should have: start, thinking_start, thinking_delta, text_start, text_delta, thinking_end, text_end, done
      expect(eventTypes).toContain('start');
      expect(eventTypes).toContain('thinking_start');
      expect(eventTypes).toContain('thinking_delta');
      expect(eventTypes).toContain('text_start');
      expect(eventTypes).toContain('text_delta');
      expect(eventTypes).toContain('thinking_end');
      expect(eventTypes).toContain('text_end');
      expect(eventTypes).toContain('done');

      // Verify order: thinking_start should come before text_start
      const thinkingStartIdx = eventTypes.indexOf('thinking_start');
      const textStartIdx = eventTypes.indexOf('text_start');
      expect(thinkingStartIdx).toBeLessThan(textStartIdx);
    });

    it('should include ThinkingContent in final message', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"My reasoning","summary_index":0}\n\n',
        'data: {"type":"response.output_text.delta","delta":"My answer"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"My reasoning"}]},{"type":"message","content":[{"type":"output_text","text":"My answer"}]}],"usage":{"input_tokens":10,"output_tokens":15}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.content).toBeDefined();

      // Should have thinking content
      const thinkingContent = doneEvent.message.content.find((c: any) => c.type === 'thinking');
      expect(thinkingContent).toBeDefined();
      expect(thinkingContent.thinking).toBe('My reasoning');

      // Should have text content
      const textContent = doneEvent.message.content.find((c: any) => c.type === 'text');
      expect(textContent).toBeDefined();
      expect(textContent.text).toBe('My answer');
    });
  });

  describe('Edge Cases', () => {
    it('should handle empty reasoning summary gracefully', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        // No delta events
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should still work without erroring
      expect(events.map(e => e.type)).toContain('done');
    });

    it('should handle reasoning without text response', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"Just thinking","summary_index":0}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Just thinking"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      // Should have thinking but no text
      const thinkingContent = doneEvent.message.content.find((c: any) => c.type === 'thinking');
      expect(thinkingContent).toBeDefined();
    });

    it('should handle text without reasoning (no regression)', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.output_text.delta","delta":"Hello "}\n\n',
        'data: {"type":"response.output_text.delta","delta":"world!"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"message","content":[{"type":"output_text","text":"Hello world!"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Say hello' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      const eventTypes = events.map(e => e.type);

      // Should NOT have thinking events
      expect(eventTypes).not.toContain('thinking_start');
      expect(eventTypes).not.toContain('thinking_delta');
      expect(eventTypes).not.toContain('thinking_end');

      // Should have text events
      expect(eventTypes).toContain('text_start');
      expect(eventTypes).toContain('text_delta');
      expect(eventTypes).toContain('text_end');
    });

    it('should handle tool calls with reasoning', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.reasoning_summary_part.added","summary_index":0}\n\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"I need to read the file","summary_index":0}\n\n',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_123","name":"read","arguments":""}}\n\n',
        'data: {"type":"response.function_call_arguments.delta","call_id":"call_123","delta":"{\\"path\\":\\"/test.txt\\"}"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"I need to read the file"}]},{"type":"function_call","call_id":"call_123","name":"read","arguments":"{\\"path\\":\\"/test.txt\\"}"}],"usage":{"input_tokens":10,"output_tokens":20}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Read the file' }],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object' as const, properties: { path: { type: 'string' as const } }, required: ['path'] },
        }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.stopReason).toBe('tool_use');

      // Should have both thinking and tool call
      const thinkingContent = doneEvent.message.content.find((c: any) => c.type === 'thinking');
      expect(thinkingContent).toBeDefined();

      const toolCall = doneEvent.message.content.find((c: any) => c.type === 'tool_use');
      expect(toolCall).toBeDefined();
      expect(toolCall.name).toBe('read');
    });

    it('should deduplicate thinking content across different event types', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      // Simulate scenario where same thinking content appears in multiple event types
      const mockStreamData = [
        // First via output_item.done with summary
        'data: {"type":"response.output_item.added","item":{"type":"reasoning"}}\n\n',
        'data: {"type":"response.output_item.done","item":{"type":"reasoning","summary":[{"type":"summary_text","text":"Thinking about this"}]}}\n\n',
        // Then the same text via delta event (should be skipped)
        'data: {"type":"response.reasoning_summary_text.delta","delta":"Thinking about this"}\n\n',
        'data: {"type":"response.output_text.delta","delta":"Hello!"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Thinking about this"}]},{"type":"message","content":[{"type":"output_text","text":"Hello!"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
      };

      const events: StreamEvent[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Count thinking_delta events - should only have one
      const thinkingDeltas = events.filter(e => e.type === 'thinking_delta');
      expect(thinkingDeltas).toHaveLength(1);

      // Verify the done message has thinking only once
      const doneEvent = events.find(e => e.type === 'done') as any;
      expect(doneEvent).toBeDefined();
      const thinkingContent = doneEvent.message.content.find((c: any) => c.type === 'thinking');
      expect(thinkingContent?.thinking).toBe('Thinking about this');
    });
  });

  describe('Regression Tests', () => {
    it('should still stream text correctly (no reasoning)', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.output_text.delta","delta":"Hello!"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"message","content":[{"type":"output_text","text":"Hello!"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hi' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.role).toBe('assistant');
      const textContent = doneEvent.message.content.find((c: any) => c.type === 'text');
      expect(textContent?.text).toBe('Hello!');
    });

    it('should still stream tool calls correctly', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_abc","name":"read","arguments":""}}\n\n',
        'data: {"type":"response.function_call_arguments.delta","call_id":"call_abc","delta":"{\\"path\\":\\"/file.txt\\"}"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"function_call","call_id":"call_abc","name":"read","arguments":"{\\"path\\":\\"/file.txt\\"}"}],"usage":{"input_tokens":10,"output_tokens":20}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Read the file' }],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object' as const, properties: { path: { type: 'string' as const } }, required: ['path'] },
        }],
      };

      const toolCallEvents: any[] = [];
      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'toolcall_start' || event.type === 'toolcall_delta' || event.type === 'toolcall_end') {
          toolCallEvents.push(event);
        }
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(toolCallEvents.length).toBeGreaterThan(0);
      expect(doneEvent.message.stopReason).toBe('tool_use');
    });
  });

  describe('Complete Method', () => {
    it('should return AssistantMessage', async () => {
      const provider = new OpenAIProvider({
        model: 'gpt-5.2-codex',
        auth: createMockAuth(),
        retry: false,
      });

      const mockStreamData = [
        'data: {"type":"response.output_text.delta","delta":"Hello!"}\n\n',
        'data: {"type":"response.completed","response":{"id":"resp-123","output":[{"type":"message","content":[{"type":"output_text","text":"Hello!"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}\n\n',
      ];

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: createMockStream(mockStreamData),
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Say hello' }],
      };

      const result = await provider.complete(context);

      expect(result.role).toBe('assistant');
      expect(result.content).toBeDefined();
    });
  });
});
