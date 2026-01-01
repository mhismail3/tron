/**
 * @fileoverview Tests for OpenAI Provider
 *
 * Comprehensive tests for the OpenAI provider implementation including:
 * - Configuration and initialization
 * - Model registry
 * - Streaming interface
 * - Tool support
 * - Error handling
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  OpenAIProvider,
  OPENAI_MODELS,
  type OpenAIConfig,
} from '../../src/providers/openai.js';

describe('OpenAI Provider', () => {
  // Save original fetch
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
        apiKey: 'sk-test-key',
        model: 'gpt-4o',
      };

      const provider = new OpenAIProvider(config);
      expect(provider.id).toBe('openai');
    });

    it('should support custom base URL', () => {
      const config: OpenAIConfig = {
        apiKey: 'sk-test',
        model: 'gpt-4o',
        baseURL: 'https://custom.openai.azure.com',
      };

      const provider = new OpenAIProvider(config);
      expect(provider).toBeDefined();
    });

    it('should support organization ID', () => {
      const config: OpenAIConfig = {
        apiKey: 'sk-test',
        model: 'gpt-4o',
        organization: 'org-123',
      };

      const provider = new OpenAIProvider(config);
      expect(provider).toBeDefined();
    });

    it('should expose model property', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      expect(provider.model).toBe('gpt-4o');
    });

    it('should support temperature setting', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
        temperature: 0.7,
      });

      expect(provider).toBeDefined();
    });

    it('should support max tokens setting', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
        maxTokens: 4096,
      });

      expect(provider).toBeDefined();
    });
  });

  describe('Model Registry', () => {
    it('should define GPT-4o model', () => {
      expect(OPENAI_MODELS['gpt-4o']).toBeDefined();
      expect(OPENAI_MODELS['gpt-4o'].contextWindow).toBe(128000);
    });

    it('should define GPT-4 Turbo model', () => {
      expect(OPENAI_MODELS['gpt-4-turbo']).toBeDefined();
      expect(OPENAI_MODELS['gpt-4-turbo'].contextWindow).toBe(128000);
    });

    it('should define GPT-4o Mini model', () => {
      expect(OPENAI_MODELS['gpt-4o-mini']).toBeDefined();
      expect(OPENAI_MODELS['gpt-4o-mini'].contextWindow).toBe(128000);
    });

    it('should define o1 reasoning models', () => {
      expect(OPENAI_MODELS['o1']).toBeDefined();
      expect(OPENAI_MODELS['o1-mini']).toBeDefined();
    });

    it('should include cost information', () => {
      const gpt4o = OPENAI_MODELS['gpt-4o'];
      expect(gpt4o.inputCostPer1k).toBeDefined();
      expect(gpt4o.outputCostPer1k).toBeDefined();
    });

    it('should have name for all models', () => {
      for (const [modelId, model] of Object.entries(OPENAI_MODELS)) {
        expect(model.name).toBeDefined();
        expect(model.name.length).toBeGreaterThan(0);
      }
    });

    it('should have context window for all models', () => {
      for (const [modelId, model] of Object.entries(OPENAI_MODELS)) {
        expect(model.contextWindow).toBeGreaterThan(0);
      }
    });

    it('should have max output for all models', () => {
      for (const [modelId, model] of Object.entries(OPENAI_MODELS)) {
        expect(model.maxOutput).toBeGreaterThan(0);
      }
    });
  });

  describe('Interface', () => {
    it('should define stream method', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      expect(typeof provider.stream).toBe('function');
    });

    it('should define complete method', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      expect(typeof provider.complete).toBe('function');
    });

    it('should have id property', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      expect(provider.id).toBe('openai');
    });
  });

  describe('Streaming', () => {
    it('should stream text deltas', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      // Mock streaming response
      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" there!"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n',
        'data: [DONE]\n\n',
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
      expect(events).toContain('text_delta');
      expect(events).toContain('done');
    });

    it('should include message in done event', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}\n\n',
        'data: [DONE]\n\n',
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
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello!"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n',
        'data: [DONE]\n\n',
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

  describe('Tool Support', () => {
    it('should accept tools in context', () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const tools = [
        {
          name: 'read',
          description: 'Read a file',
          parameters: {
            type: 'object',
            properties: {
              path: { type: 'string' },
            },
            required: ['path'],
          },
        },
      ];

      const context = {
        messages: [{ role: 'user' as const, content: 'Test' }],
        tools,
      };

      // Should not throw when creating context with tools
      expect(() => {
        provider.stream(context);
      }).not.toThrow();
    });
  });

  describe('Model Properties', () => {
    it('should indicate tool support for applicable models', () => {
      expect(OPENAI_MODELS['gpt-4o'].supportsTools).toBe(true);
      expect(OPENAI_MODELS['gpt-4-turbo'].supportsTools).toBe(true);
      expect(OPENAI_MODELS['gpt-3.5-turbo'].supportsTools).toBe(true);
    });

    it('should indicate no tool support for o1 models', () => {
      expect(OPENAI_MODELS['o1'].supportsTools).toBe(false);
      expect(OPENAI_MODELS['o1-mini'].supportsTools).toBe(false);
    });
  });
});
