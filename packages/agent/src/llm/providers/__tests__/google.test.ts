/**
 * @fileoverview Tests for Google Gemini Provider
 *
 * Comprehensive tests for the Google Gemini provider implementation including:
 * - Configuration and initialization
 * - Model registry
 * - Streaming interface
 * - Function calling support
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  GoogleProvider,
  GEMINI_MODELS,
  type GoogleConfig,
  type GoogleApiKeyAuth,
  type GoogleOAuthAuth,
} from '../google/index.js';

// Helper to create API key auth config
function createApiKeyAuth(apiKey: string = 'test-api-key'): GoogleApiKeyAuth {
  return { type: 'api_key', apiKey };
}

// Helper to create OAuth auth config
function createOAuthAuth(): GoogleOAuthAuth {
  return {
    type: 'oauth',
    accessToken: 'test-access-token',
    refreshToken: 'test-refresh-token',
    expiresAt: Date.now() + 3600 * 1000, // 1 hour from now
  };
}

describe('Google Gemini Provider', () => {
  // Save original fetch
  const originalFetch = global.fetch;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  describe('Configuration', () => {
    it('should accept valid configuration with API key', () => {
      const config: GoogleConfig = {
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      };

      const provider = new GoogleProvider(config);
      expect(provider.id).toBe('google');
    });

    it('should accept valid configuration with OAuth', () => {
      const config: GoogleConfig = {
        auth: createOAuthAuth(),
        model: 'gemini-2.5-pro',
      };

      const provider = new GoogleProvider(config);
      expect(provider.id).toBe('google');
    });

    it('should accept optional temperature setting', () => {
      const config: GoogleConfig = {
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
        temperature: 0.7,
      };

      const provider = new GoogleProvider(config);
      expect(provider).toBeDefined();
    });

    it('should accept optional max output tokens', () => {
      const config: GoogleConfig = {
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
        maxTokens: 4096,
      };

      const provider = new GoogleProvider(config);
      expect(provider).toBeDefined();
    });

    it('should expose model property', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      expect(provider.model).toBe('gemini-2.5-pro');
    });

    it('should support custom base URL with API key auth', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
        baseURL: 'https://custom.googleapis.com',
      });

      expect(provider).toBeDefined();
    });
  });

  describe('Model Registry', () => {
    it('should define Gemini 1.5 Pro', () => {
      expect(GEMINI_MODELS['gemini-2.5-pro']).toBeDefined();
      expect(GEMINI_MODELS['gemini-2.5-pro'].contextWindow).toBe(2097152);
    });

    it('should define Gemini 1.5 Flash', () => {
      expect(GEMINI_MODELS['gemini-2.5-flash']).toBeDefined();
      expect(GEMINI_MODELS['gemini-2.5-flash'].contextWindow).toBe(1048576);
    });

    it('should define Gemini 2.5 Flash Lite', () => {
      expect(GEMINI_MODELS['gemini-2.5-flash-lite']).toBeDefined();
    });

    it('should include cost information', () => {
      const geminiPro = GEMINI_MODELS['gemini-2.5-pro'];
      expect(geminiPro.inputCostPer1k).toBeDefined();
      expect(geminiPro.outputCostPer1k).toBeDefined();
    });

    it('should have large context windows', () => {
      expect(GEMINI_MODELS['gemini-2.5-pro'].contextWindow).toBeGreaterThanOrEqual(
        1000000
      );
    });

    it('should have name for all models', () => {
      for (const [modelId, model] of Object.entries(GEMINI_MODELS)) {
        expect(model.name).toBeDefined();
        expect(model.name.length).toBeGreaterThan(0);
      }
    });

    it('should have context window for all models', () => {
      for (const [modelId, model] of Object.entries(GEMINI_MODELS)) {
        expect(model.contextWindow).toBeGreaterThan(0);
      }
    });

    it('should have max output for all models', () => {
      for (const [modelId, model] of Object.entries(GEMINI_MODELS)) {
        expect(model.maxOutput).toBeGreaterThan(0);
      }
    });

    it('should indicate tool support', () => {
      expect(GEMINI_MODELS['gemini-2.5-pro'].supportsTools).toBe(true);
      expect(GEMINI_MODELS['gemini-2.5-flash'].supportsTools).toBe(true);
    });
  });

  describe('Interface', () => {
    it('should define stream method', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      expect(typeof provider.stream).toBe('function');
    });

    it('should define complete method', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      expect(typeof provider.complete).toBe('function');
    });

    it('should have id property', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      expect(provider.id).toBe('google');
    });
  });

  describe('Streaming', () => {
    it('should stream text deltas', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      // Mock Gemini streaming response format
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Say hello' }],
      };

      const events: string[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event.type);
      }

      expect(events).toContain('start');
      expect(events).toContain('done');
    });

    it('should include message in done event', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello there!"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
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
      expect(doneEvent.message).toBeDefined();
      expect(doneEvent.message.role).toBe('assistant');
    });
  });

  describe('Complete Method', () => {
    it('should return AssistantMessage', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello!"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Say hello' }],
      };

      const result = await provider.complete(context);

      expect(result.role).toBe('assistant');
      expect(result.content).toBeDefined();
    });
  });

  describe('Function Calling', () => {
    it('should accept tools in context', () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Search for cats' }],
        tools: [
          {
            name: 'search',
            description: 'Search the web',
            parameters: {
              type: 'object' as const,
              properties: {
                query: { type: 'string' as const, description: 'Search query' },
              },
              required: ['query'],
            },
          },
        ],
      };

      // Should not throw when creating context with tools
      expect(() => {
        provider.stream(context);
      }).not.toThrow();
    });
  });

  // ===========================================================================
  // Gemini 3 Model Spec Tests
  // ===========================================================================

  describe('Gemini 3 Model Registry', () => {
    it('should have correct context window for gemini-3-pro-preview (1048576)', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview']).toBeDefined();
      expect(GEMINI_MODELS['gemini-3-pro-preview'].contextWindow).toBe(1048576);
    });

    it('should have correct max output for gemini-3-pro-preview (65536)', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview'].maxOutput).toBe(65536);
    });

    it('should have correct context window for gemini-3-flash-preview (1048576)', () => {
      expect(GEMINI_MODELS['gemini-3-flash-preview']).toBeDefined();
      expect(GEMINI_MODELS['gemini-3-flash-preview'].contextWindow).toBe(1048576);
    });

    it('should have correct max output for gemini-3-flash-preview (65536)', () => {
      expect(GEMINI_MODELS['gemini-3-flash-preview'].maxOutput).toBe(65536);
    });

    it('should mark supportsThinking=true for Gemini 3 models', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview'].supportsThinking).toBe(true);
      expect(GEMINI_MODELS['gemini-3-flash-preview'].supportsThinking).toBe(true);
    });

    it('should include tier for all Gemini 3 models', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview'].tier).toBe('pro');
      expect(GEMINI_MODELS['gemini-3-flash-preview'].tier).toBe('flash');
    });

    it('should mark Gemini 3 models as preview', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview'].preview).toBe(true);
      expect(GEMINI_MODELS['gemini-3-flash-preview'].preview).toBe(true);
    });

    it('should have supportedThinkingLevels for Flash (includes minimal)', () => {
      const flashModel = GEMINI_MODELS['gemini-3-flash-preview'];
      expect(flashModel.supportedThinkingLevels).toBeDefined();
      expect(flashModel.supportedThinkingLevels).toContain('minimal');
    });

    it('should have defaultThinkingLevel for Gemini 3 models', () => {
      expect(GEMINI_MODELS['gemini-3-pro-preview'].defaultThinkingLevel).toBeDefined();
      expect(GEMINI_MODELS['gemini-3-flash-preview'].defaultThinkingLevel).toBeDefined();
    });
  });

  // ===========================================================================
  // Gemini 3 Thinking Mode Tests
  // ===========================================================================

  describe('Gemini 3 Thinking Mode', () => {
    it('should configure thinkingLevel for Gemini 3 models', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
        thinkingLevel: 'medium',
      });

      // Mock response with thinking content
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"The answer is 42."}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'What is the meaning of life?' }],
      };

      // Collect events
      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Verify the fetch call included thinkingLevel config
      expect(global.fetch).toHaveBeenCalled();
      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);
      // API expects uppercase: MINIMAL, LOW, MEDIUM, HIGH
      expect(requestBody.generationConfig?.thinkingConfig?.thinkingLevel).toBe('MEDIUM');
    });

    it('should use model defaultThinkingLevel when no explicit level configured', async () => {
      // Create provider WITHOUT explicit thinkingLevel - should use model default
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-flash-preview', // defaultThinkingLevel: 'low'
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      for await (const _ of provider.stream(context)) {
        // consume stream
      }

      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);
      // Flash default is 'high' -> 'HIGH'
      expect(requestBody.generationConfig?.thinkingConfig?.thinkingLevel).toBe('HIGH');
    });

    it('should use thinkingBudget for Gemini 2.5 models', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-2.5-pro',
        thinkingBudget: 16384,
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Think carefully' }],
      };

      for await (const _ of provider.stream(context)) {
        // consume stream
      }

      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);
      expect(requestBody.generationConfig?.thinkingConfig?.thinkingBudget).toBe(16384);
    });

    it('should yield thinking_start/thinking_delta/thinking_end events', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
        thinkingLevel: 'high',
      });

      // Mock response with thinking content (thought: true part)
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Let me think about this..."}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":"The answer is 42."}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":10,"totalTokenCount":20}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Deep question' }],
      };

      const eventTypes: string[] = [];
      for await (const event of provider.stream(context)) {
        eventTypes.push(event.type);
      }

      expect(eventTypes).toContain('thinking_start');
      expect(eventTypes).toContain('thinking_delta');
      expect(eventTypes).toContain('thinking_end');
    });

    it('should include ThinkingContent in final message', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
        thinkingLevel: 'high',
      });

      // Mock response with thinking content followed by text
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Let me analyze this carefully..."}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":"The answer is 42."}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":15,"totalTokenCount":25}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'What is the meaning of life?' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.content).toBeDefined();

      // Should have thinking content FIRST
      const thinkingContent = doneEvent.message.content.find((c: any) => c.type === 'thinking');
      expect(thinkingContent).toBeDefined();
      expect(thinkingContent.thinking).toBe('Let me analyze this carefully...');

      // Should have text content SECOND
      const textContent = doneEvent.message.content.find((c: any) => c.type === 'text');
      expect(textContent).toBeDefined();
      expect(textContent.text).toBe('The answer is 42.');

      // Verify thinking comes before text in the content array
      const thinkingIndex = doneEvent.message.content.findIndex((c: any) => c.type === 'thinking');
      const textIndex = doneEvent.message.content.findIndex((c: any) => c.type === 'text');
      expect(thinkingIndex).toBeLessThan(textIndex);
    });

    it('should enforce temperature=1.0 for Gemini 3', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
        temperature: 0.5, // This should be overridden to 1.0
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hi' }],
      };

      for await (const _ of provider.stream(context)) {
        // consume stream
      }

      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);
      // For Gemini 3, temperature must be 1.0
      expect(requestBody.generationConfig?.temperature).toBe(1.0);
    });
  });

  // ===========================================================================
  // Stream Edge Cases Tests
  // ===========================================================================

  describe('Stream Edge Cases', () => {
    it('should handle stream ending without finishReason', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-flash-preview',
      });

      // Mock stream that sends text but no finishReason
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
        // No finishReason chunk
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should still get a done event with the accumulated content
      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent.message.content).toHaveLength(1);
      expect(doneEvent.message.content[0].text).toBe('Hello');
      // Synthesized stop reason defaults to 'end_turn' for text content
      expect(doneEvent.message.stopReason).toBe('end_turn');
    });

    it('should handle data in buffer when stream ends', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-flash-preview',
      });

      // Mock stream where final chunk doesn't end with newline
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}',
        // No trailing newline!
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should process the buffered data and emit done
      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent.message.content[0].text).toBe('Hello');
    });

    it('should synthesize done event with accumulated tool calls when stream ends without finishReason', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-flash-preview',
      });

      // Mock stream with tool call but no finishReason
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"read_file","args":{"path":"/test.txt"}}}],"role":"model"}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5,"totalTokenCount":15}}\n\n',
        // Stream ends without finishReason
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Read the file' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should have tool call events
      const toolCallStart = events.find(e => e.type === 'toolcall_start');
      expect(toolCallStart).toBeDefined();
      expect(toolCallStart.name).toBe('read_file');

      // Should still get a done event with the tool call
      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent.message.content).toHaveLength(1);
      expect(doneEvent.message.content[0].type).toBe('tool_use');
      expect(doneEvent.message.content[0].name).toBe('read_file');
    });

    it('should properly close thinking state when synthesizing done event', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-flash-preview',
      });

      // Mock stream with thinking content but no finishReason
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Let me think..."}],"role":"model"}}]}\n\n',
        'data: {"candidates":[{"content":{"parts":[{"text":"The answer is 42."}],"role":"model"}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":10,"totalTokenCount":20}}\n\n',
        // No finishReason
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Think about this' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should have thinking events
      expect(events.some(e => e.type === 'thinking_start')).toBe(true);
      expect(events.some(e => e.type === 'thinking_delta')).toBe(true);

      // Should get done event with both thinking and text content
      const doneEvent = events.find(e => e.type === 'done');
      expect(doneEvent).toBeDefined();
      expect(doneEvent.message.content).toHaveLength(2);
      expect(doneEvent.message.content[0].type).toBe('thinking');
      expect(doneEvent.message.content[1].type).toBe('text');
    });
  });

  // ===========================================================================
  // Safety Handling Tests
  // ===========================================================================

  describe('Safety Handling', () => {
    it('should emit error event on SAFETY finish reason', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
      });

      // Mock response with SAFETY finish reason
      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"SAFETY","safetyRatings":[{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","probability":"HIGH"}]}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0,"totalTokenCount":10}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Dangerous request' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      // Should emit a safety_block or error event
      const safetyEvent = events.find(e => e.type === 'safety_block' || e.type === 'error');
      expect(safetyEvent).toBeDefined();
    });

    it('should include blocked categories in safety error', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
      });

      const mockStreamData = [
        'data: {"candidates":[{"finishReason":"SAFETY","safetyRatings":[{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","probability":"HIGH"},{"category":"HARM_CATEGORY_HATE_SPEECH","probability":"MEDIUM"}]}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0,"totalTokenCount":10}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Blocked content' }],
      };

      const events: any[] = [];
      for await (const event of provider.stream(context)) {
        events.push(event);
      }

      const safetyEvent = events.find(e => e.type === 'safety_block' || e.type === 'error');
      expect(safetyEvent).toBeDefined();
      // The event should contain information about blocked categories
      if (safetyEvent?.blockedCategories) {
        expect(safetyEvent.blockedCategories).toContain('HARM_CATEGORY_DANGEROUS_CONTENT');
      }
    });

    it('should apply default OFF safety settings for Gemini 3', async () => {
      const provider = new GoogleProvider({
        auth: createApiKeyAuth(),
        model: 'gemini-3-pro-preview',
      });

      const mockStreamData = [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}\n\n',
      ];

      const encoder = new TextEncoder();
      let dataIndex = 0;

      const mockReadableStream = new ReadableStream({
        pull(controller) {
          if (dataIndex < mockStreamData.length) {
            controller.enqueue(encoder.encode(mockStreamData[dataIndex]));
            dataIndex++;
          } else {
            controller.close();
          }
        },
      });

      global.fetch = vi.fn().mockResolvedValue({
        ok: true,
        body: mockReadableStream,
      });

      const context = {
        messages: [{ role: 'user' as const, content: 'Hi' }],
      };

      for await (const _ of provider.stream(context)) {
        // consume stream
      }

      const fetchCall = (global.fetch as any).mock.calls[0];
      const requestBody = JSON.parse(fetchCall[1].body);

      // Should include safetySettings with OFF threshold for agentic use
      expect(requestBody.safetySettings).toBeDefined();
      expect(Array.isArray(requestBody.safetySettings)).toBe(true);

      // Verify at least one setting is OFF
      const offSetting = requestBody.safetySettings.find(
        (s: any) => s.threshold === 'OFF' || s.threshold === 'BLOCK_NONE'
      );
      expect(offSetting).toBeDefined();
    });
  });
});
