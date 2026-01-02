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
} from '../../src/providers/google.js';

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
    it('should accept valid configuration', () => {
      const config: GoogleConfig = {
        apiKey: 'test-api-key',
        model: 'gemini-2.5-pro',
      };

      const provider = new GoogleProvider(config);
      expect(provider.id).toBe('google');
    });

    it('should accept optional temperature setting', () => {
      const config: GoogleConfig = {
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
        temperature: 0.7,
      };

      const provider = new GoogleProvider(config);
      expect(provider).toBeDefined();
    });

    it('should accept optional max output tokens', () => {
      const config: GoogleConfig = {
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
        maxTokens: 4096,
      };

      const provider = new GoogleProvider(config);
      expect(provider).toBeDefined();
    });

    it('should expose model property', () => {
      const provider = new GoogleProvider({
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
      });

      expect(provider.model).toBe('gemini-2.5-pro');
    });

    it('should support custom base URL', () => {
      const provider = new GoogleProvider({
        apiKey: 'test-key',
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

    it('should define Gemini 2.0 models', () => {
      expect(GEMINI_MODELS['gemini-2.0-flash']).toBeDefined();
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
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
      });

      expect(typeof provider.stream).toBe('function');
    });

    it('should define complete method', () => {
      const provider = new GoogleProvider({
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
      });

      expect(typeof provider.complete).toBe('function');
    });

    it('should have id property', () => {
      const provider = new GoogleProvider({
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
      });

      expect(provider.id).toBe('google');
    });
  });

  describe('Streaming', () => {
    it('should stream text deltas', async () => {
      const provider = new GoogleProvider({
        apiKey: 'test-key',
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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
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
        apiKey: 'test-key',
        model: 'gemini-2.5-pro',
      });

      const tools = [
        {
          name: 'search',
          description: 'Search the web',
          parameters: {
            type: 'object',
            properties: {
              query: { type: 'string', description: 'Search query' },
            },
            required: ['query'],
          },
        },
      ];

      const context = {
        messages: [{ role: 'user' as const, content: 'Search for cats' }],
        tools,
      };

      // Should not throw when creating context with tools
      expect(() => {
        provider.stream(context);
      }).not.toThrow();
    });
  });
});
