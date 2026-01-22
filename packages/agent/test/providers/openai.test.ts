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
      expect(OPENAI_MODELS['gpt-4o-mini'].supportsTools).toBe(true);
    });

    it('should indicate no tool support for o1 models', () => {
      expect(OPENAI_MODELS['o1'].supportsTools).toBe(false);
      expect(OPENAI_MODELS['o1-mini'].supportsTools).toBe(false);
    });
  });

  describe('Tool Calling', () => {
    it('should stream tool call with correct stop reason', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"/test.txt\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":30,"total_tokens":80}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Read the test file' }],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
        }],
      };

      let doneEvent: any = null;
      const toolCallEndEvents: any[] = [];
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
        if (event.type === 'toolcall_end') {
          toolCallEndEvents.push(event);
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.stopReason).toBe('tool_use');
      expect(toolCallEndEvents).toHaveLength(1);
      expect(toolCallEndEvents[0].toolCall.name).toBe('read');
      expect(toolCallEndEvents[0].toolCall.arguments).toEqual({ path: '/test.txt' });
    });

    it('should handle malformed tool call arguments gracefully', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      // Simulate malformed JSON in tool call arguments
      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_bad","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{ malformed json"}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":30,"total_tokens":80}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Read something' }],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
        }],
      };

      let doneEvent: any = null;
      let errorEvent: any = null;
      const toolCallEndEvents: any[] = [];

      for await (const event of provider.stream(context)) {
        if (event.type === 'done') doneEvent = event;
        if (event.type === 'error') errorEvent = event;
        if (event.type === 'toolcall_end') toolCallEndEvents.push(event);
      }

      // Should not error out - should handle gracefully with empty args
      expect(errorEvent).toBeNull();
      expect(doneEvent).not.toBeNull();
      expect(toolCallEndEvents).toHaveLength(1);
      // Malformed JSON should result in empty object
      expect(toolCallEndEvents[0].toolCall.arguments).toEqual({});
    });
  });

  describe('Cache Token Extraction', () => {
    it('should extract cached_tokens from prompt_tokens_details', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      // Mock response with prompt_tokens_details.cached_tokens
      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello!"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1000,"completion_tokens":5,"total_tokens":1005,"prompt_tokens_details":{"cached_tokens":800}}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.usage).toBeDefined();
      expect(doneEvent.message.usage.inputTokens).toBe(1000);
      expect(doneEvent.message.usage.outputTokens).toBe(5);
      expect(doneEvent.message.usage.cacheReadTokens).toBe(800);
    });

    it('should handle missing prompt_tokens_details gracefully', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      // Mock response without prompt_tokens_details
      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello!"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":500,"completion_tokens":5,"total_tokens":505}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.usage.inputTokens).toBe(500);
      expect(doneEvent.message.usage.outputTokens).toBe(5);
      expect(doneEvent.message.usage.cacheReadTokens).toBe(0);
    });

    it('should handle prompt_tokens_details without cached_tokens', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      // Mock response with prompt_tokens_details but no cached_tokens
      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello!"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":500,"completion_tokens":5,"total_tokens":505,"prompt_tokens_details":{}}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Hello' }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.usage.inputTokens).toBe(500);
      expect(doneEvent.message.usage.cacheReadTokens).toBe(0);
    });
  });

  describe('Multi-Turn Conversation', () => {
    it('should properly convert tool result messages', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"The file contains: test content"},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110}}\n\n',
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

      // Simulate a multi-turn conversation with tool results
      const context = {
        messages: [
          { role: 'user' as const, content: 'Read the test file' },
          {
            role: 'assistant' as const,
            content: [{
              type: 'tool_use' as const,
              id: 'call_abc123',
              name: 'read',
              arguments: { path: '/test.txt' },
            }],
          },
          {
            role: 'toolResult' as const,
            toolCallId: 'call_abc123',
            content: 'test content',
          },
        ],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
        }],
      };

      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(doneEvent).not.toBeNull();
      expect(doneEvent.message.stopReason).toBe('end_turn');

      // Verify the fetch was called with properly formatted messages
      expect(global.fetch).toHaveBeenCalled();
      const fetchCall = (global.fetch as any).mock.calls[0];
      const body = JSON.parse(fetchCall[1].body);

      // Check that messages were properly converted (user + assistant + tool)
      expect(body.messages).toHaveLength(3);
      expect(body.messages[0].role).toBe('user');
      expect(body.messages[1].role).toBe('assistant');
      expect(body.messages[1].tool_calls).toBeDefined();
      expect(body.messages[1].tool_calls[0].id).toBe('call_abc123');
      expect(body.messages[2].role).toBe('tool');
      expect(body.messages[2].tool_call_id).toBe('call_abc123');
      expect(body.messages[2].content).toBe('test content');
    });

    it('should handle multiple tool calls in one turn', async () => {
      const provider = new OpenAIProvider({
        apiKey: 'sk-test',
        model: 'gpt-4o',
      });

      const mockStreamData = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"I\'ll read both files.","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":""}},{"index":1,"id":"call_2","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"/file1.txt\\"}"}},{"index":1,"function":{"arguments":"{\\"path\\":\\"/file2.txt\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":50,"total_tokens":100}}\n\n',
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
        messages: [{ role: 'user' as const, content: 'Read both files' }],
        tools: [{
          name: 'read',
          description: 'Read a file',
          parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
        }],
      };

      const toolCallEndEvents: any[] = [];
      let doneEvent: any = null;
      for await (const event of provider.stream(context)) {
        if (event.type === 'toolcall_end') {
          toolCallEndEvents.push(event);
        }
        if (event.type === 'done') {
          doneEvent = event;
        }
      }

      expect(toolCallEndEvents).toHaveLength(2);
      expect(toolCallEndEvents[0].toolCall.id).toBe('call_1');
      expect(toolCallEndEvents[0].toolCall.arguments.path).toBe('/file1.txt');
      expect(toolCallEndEvents[1].toolCall.id).toBe('call_2');
      expect(toolCallEndEvents[1].toolCall.arguments.path).toBe('/file2.txt');

      // Verify final message contains both tool calls
      expect(doneEvent.message.content).toHaveLength(3); // text + 2 tool calls
    });
  });
});
