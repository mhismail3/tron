/**
 * @fileoverview Tests for Anthropic provider
 *
 * TDD: Tests for Claude API integration
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type {
  AnthropicProvider,
  AnthropicConfig,
  StreamOptions,
} from '../anthropic.js';
import type { Context, Message, StreamEvent, ThinkingContent, TextContent, ToolCall } from '../types/index.js';

// Mock the Anthropic SDK
vi.mock('@anthropic-ai/sdk', () => ({
  default: vi.fn().mockImplementation(() => ({
    messages: {
      stream: vi.fn().mockReturnValue({
        [Symbol.asyncIterator]: async function* () {
          yield { type: 'message_start', message: { id: 'msg_123' } };
          yield { type: 'content_block_start', index: 0, content_block: { type: 'text' } };
          yield { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello' } };
          yield { type: 'content_block_delta', delta: { type: 'text_delta', text: ' world' } };
          yield { type: 'content_block_stop' };
          yield { type: 'message_stop' };
        },
        finalMessage: () => ({
          id: 'msg_123',
          role: 'assistant',
          content: [{ type: 'text', text: 'Hello world' }],
          stop_reason: 'end_turn',
          usage: { input_tokens: 10, output_tokens: 5 },
        }),
      }),
    },
  })),
}));

describe('Anthropic Provider', () => {
  describe('AnthropicConfig', () => {
    it('should define required configuration fields', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: {
          type: 'api_key',
          apiKey: 'sk-ant-test',
        },
      };

      expect(config.model).toBe('claude-sonnet-4-20250514');
      expect(config.auth.type).toBe('api_key');
    });

    it('should support OAuth configuration', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: {
          type: 'oauth',
          accessToken: 'sk-ant-oat-test',
          refreshToken: 'refresh-token',
          expiresAt: Date.now() + 3600000,
        },
      };

      expect(config.auth.type).toBe('oauth');
    });

    it('should support optional parameters', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'test' },
        maxTokens: 4096,
        temperature: 0.7,
        thinkingBudget: 2048,
      };

      expect(config.maxTokens).toBe(4096);
      expect(config.temperature).toBe(0.7);
      expect(config.thinkingBudget).toBe(2048);
    });
  });

  describe('StreamOptions', () => {
    it('should define streaming options', () => {
      const options: StreamOptions = {
        maxTokens: 4096,
        temperature: 0.5,
        enableThinking: true,
        thinkingBudget: 2048,
        stopSequences: ['END'],
      };

      expect(options.maxTokens).toBe(4096);
      expect(options.enableThinking).toBe(true);
    });

    it('should support thinking configuration', () => {
      const optionsWithThinking: StreamOptions = {
        enableThinking: true,
        thinkingBudget: 4096,
      };

      expect(optionsWithThinking.enableThinking).toBe(true);
      expect(optionsWithThinking.thinkingBudget).toBe(4096);
    });

    it('should allow disabling thinking', () => {
      const optionsWithoutThinking: StreamOptions = {
        enableThinking: false,
      };

      expect(optionsWithoutThinking.enableThinking).toBe(false);
      expect(optionsWithoutThinking.thinkingBudget).toBeUndefined();
    });
  });

  describe('Thinking Support', () => {
    describe('Message Content Types', () => {
      it('should support thinking content in messages', () => {
        const message: Message = {
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: 'Let me analyze this request' },
            { type: 'text', text: 'Here is my response' },
          ],
        };

        expect(message.content).toHaveLength(2);
        expect(message.content[0]).toMatchObject({ type: 'thinking' });
        expect(message.content[1]).toMatchObject({ type: 'text' });
      });

      it('should support thinking with tool calls', () => {
        const message: Message = {
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: 'I need to read the file first' },
            { type: 'text', text: 'Let me check that file' },
            {
              type: 'tool_use',
              id: 'toolu_123',
              name: 'Read',
              arguments: { file_path: '/test.ts' },
            },
          ],
        };

        expect(message.content).toHaveLength(3);
        expect(message.content[0]).toMatchObject({ type: 'thinking' });
        expect(message.content[1]).toMatchObject({ type: 'text' });
        expect(message.content[2]).toMatchObject({ type: 'tool_use' });
      });
    });

    describe('Model thinking support', () => {
      it('should identify models that support thinking', () => {
        // These models support thinking
        const thinkingModels = [
          'claude-opus-4-5-20251101',
          'claude-sonnet-4-5-20250929',
          'claude-haiku-4-5-20251001',
          'claude-opus-4-1-20250805',
          'claude-opus-4-20250514',
          'claude-sonnet-4-20250514',
          'claude-3-7-sonnet-20250219',
        ];

        for (const modelId of thinkingModels) {
          const config: AnthropicConfig = {
            model: modelId,
            auth: { type: 'api_key', apiKey: 'test' },
            thinkingBudget: 2048,
          };
          expect(config.thinkingBudget).toBe(2048);
        }
      });

      it('should configure thinking budget appropriately', () => {
        const config: AnthropicConfig = {
          model: 'claude-opus-4-5-20251101',
          auth: { type: 'api_key', apiKey: 'test' },
          thinkingBudget: 10000,
        };

        expect(config.thinkingBudget).toBe(10000);
      });
    });
  });
});
