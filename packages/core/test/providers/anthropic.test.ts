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
} from '../../src/providers/anthropic.js';
import type { Context, Message, StreamEvent } from '../../src/types/index.js';

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
  });
});
