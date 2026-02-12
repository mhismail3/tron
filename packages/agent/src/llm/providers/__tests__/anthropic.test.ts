/**
 * @fileoverview Tests for Anthropic provider
 *
 * TDD: Tests for Claude API integration including Opus 4.6 adaptive thinking,
 * effort parameter, and conditional beta headers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type {
  AnthropicConfig,
  StreamOptions,
} from '../anthropic/index.js';
import type { Context, Message, StreamEvent } from '@core/types/index.js';

// Capture the constructor args and stream params
let lastConstructorArgs: any;
let lastStreamParams: any;

// vi.mock factories must not reference top-level variables.
// We use vi.fn() inside the factory and set implementations in beforeEach.
vi.mock('@anthropic-ai/sdk', () => ({ default: vi.fn() }));
vi.mock('@infrastructure/settings/index.js', () => ({ getSettings: vi.fn() }));
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(), debug: vi.fn(), warn: vi.fn(), error: vi.fn(), trace: vi.fn(),
  }),
}));
vi.mock('@infrastructure/auth/oauth.js', () => ({
  shouldRefreshTokens: vi.fn(),
  refreshOAuthToken: vi.fn(),
}));
vi.mock('../anthropic/message-converter.js', () => ({
  convertMessages: vi.fn(),
  convertTools: vi.fn(),
  convertResponse: vi.fn(),
}));
vi.mock('@core/utils/message-sanitizer.js', () => ({ sanitizeMessages: vi.fn() }));
vi.mock('@core/utils/errors.js', () => ({ parseError: vi.fn(), formatError: vi.fn() }));
vi.mock('@core/utils/retry.js', () => ({
  calculateBackoffDelay: vi.fn(),
  extractRetryAfterFromError: vi.fn(),
  sleepWithAbort: vi.fn(),
}));

import Anthropic from '@anthropic-ai/sdk';
import { createLogger } from '@infrastructure/logging/index.js';
import { shouldRefreshTokens } from '@infrastructure/auth/oauth.js';
import { convertMessages, convertTools, convertResponse } from '../anthropic/message-converter.js';
import { sanitizeMessages } from '@core/utils/message-sanitizer.js';
import { AnthropicProvider } from '../anthropic/anthropic-provider.js';
import { DEFAULT_MAX_OUTPUT_TOKENS } from '@runtime/constants.js';

describe('Anthropic Provider', () => {
  const mockProviderSettings = {
    api: {
      systemPromptPrefix: "You are Claude Code.",
      oauthBetaHeaders: 'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14',
      tokenExpiryBufferSeconds: 300,
    },
    models: {
      default: 'claude-opus-4-6',
    },
    retry: {
      maxRetries: 3,
      baseDelayMs: 1000,
      maxDelayMs: 60000,
      jitterFactor: 0.2,
    },
  };

  beforeEach(() => {
    lastConstructorArgs = undefined;
    lastStreamParams = undefined;

    vi.mocked(createLogger).mockReturnValue({
      info: vi.fn(), debug: vi.fn(), warn: vi.fn(), error: vi.fn(), trace: vi.fn(),
    } as any);
    vi.mocked(shouldRefreshTokens).mockReturnValue(false);
    vi.mocked(convertMessages).mockReturnValue([]);
    vi.mocked(convertTools).mockReturnValue([]);
    vi.mocked(convertResponse).mockReturnValue({
      role: 'assistant',
      content: [{ type: 'text', text: 'Hello' }],
      usage: { inputTokens: 10, outputTokens: 5 },
    } as any);
    vi.mocked(sanitizeMessages).mockReturnValue({ messages: [], wasSanitized: false } as any);

    vi.mocked(Anthropic).mockImplementation((args: any) => {
      lastConstructorArgs = args;
      return {
        messages: {
          stream: vi.fn().mockImplementation((params: any) => {
            lastStreamParams = params;
            return {
              [Symbol.asyncIterator]: async function* () {
                yield { type: 'message_start', message: { id: 'msg_123' } };
                yield { type: 'content_block_start', index: 0, content_block: { type: 'text' } };
                yield { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello' } };
                yield { type: 'content_block_stop' };
                yield { type: 'message_stop' };
              },
              finalMessage: () => ({
                id: 'msg_123',
                role: 'assistant',
                content: [{ type: 'text', text: 'Hello' }],
                stop_reason: 'end_turn',
                usage: { input_tokens: 10, output_tokens: 5 },
              }),
            };
          }),
        },
      } as any;
    });
  });

  describe('AnthropicConfig', () => {
    it('should define required configuration fields', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'sk-ant-test' },
      };
      expect(config.model).toBe('claude-sonnet-4-20250514');
      expect(config.auth.type).toBe('api_key');
    });

    it('should support OAuth configuration', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'oauth', accessToken: 'test', refreshToken: 'refresh', expiresAt: Date.now() + 3600000 },
      };
      expect(config.auth.type).toBe('oauth');
    });

    it('should support optional parameters', () => {
      const config: AnthropicConfig = {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'test' },
        maxTokens: 4096, temperature: 0.7, thinkingBudget: 2048,
      };
      expect(config.maxTokens).toBe(4096);
      expect(config.temperature).toBe(0.7);
      expect(config.thinkingBudget).toBe(2048);
    });
  });

  describe('StreamOptions', () => {
    it('should define streaming options', () => {
      const options: StreamOptions = {
        maxTokens: 4096, temperature: 0.5, enableThinking: true, thinkingBudget: 2048, stopSequences: ['END'],
      };
      expect(options.maxTokens).toBe(4096);
      expect(options.enableThinking).toBe(true);
    });

    it('should support thinking configuration', () => {
      const opts: StreamOptions = { enableThinking: true, thinkingBudget: 4096 };
      expect(opts.enableThinking).toBe(true);
      expect(opts.thinkingBudget).toBe(4096);
    });

    it('should allow disabling thinking', () => {
      const opts: StreamOptions = { enableThinking: false };
      expect(opts.enableThinking).toBe(false);
      expect(opts.thinkingBudget).toBeUndefined();
    });

    it('should support effortLevel in stream options', () => {
      const opts: StreamOptions = { enableThinking: true, effortLevel: 'high' };
      expect(opts.effortLevel).toBe('high');
    });
  });

  describe('Thinking Support', () => {
    it('should support thinking content in messages', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: 'Let me analyze' },
          { type: 'text', text: 'Response' },
        ],
      };
      expect(message.content).toHaveLength(2);
    });

    it('should support thinking with tool calls', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: 'I need to read' },
          { type: 'text', text: 'Let me check' },
          { type: 'tool_use', id: 'toolu_123', name: 'Read', arguments: { file_path: '/test.ts' } },
        ],
      };
      expect(message.content).toHaveLength(3);
    });

    it('should identify models that support thinking', () => {
      const thinkingModels = [
        'claude-opus-4-6', 'claude-opus-4-5-20251101', 'claude-sonnet-4-5-20250929',
      ];
      for (const modelId of thinkingModels) {
        const config: AnthropicConfig = { model: modelId, auth: { type: 'api_key', apiKey: 'test' }, thinkingBudget: 2048 };
        expect(config.thinkingBudget).toBe(2048);
      }
    });
  });

  // =========================================================================
  // Opus 4.6 Provider Behavior Tests
  // =========================================================================

  async function collectStream(provider: AnthropicProvider, ctx: Context, opts: StreamOptions): Promise<StreamEvent[]> {
    const events: StreamEvent[] = [];
    for await (const event of provider.stream(ctx, opts)) {
      events.push(event);
    }
    return events;
  }

  function createApiKeyProvider(model: string): AnthropicProvider {
    return new AnthropicProvider({
      model,
      auth: { type: 'api_key', apiKey: 'sk-test' },
      providerSettings: mockProviderSettings,
    });
  }

  function createOAuthProv(model: string): AnthropicProvider {
    return new AnthropicProvider({
      model,
      auth: { type: 'oauth', accessToken: 'token', refreshToken: 'refresh', expiresAt: Date.now() + 3600000 },
      providerSettings: mockProviderSettings,
    });
  }

  const ctx: Context = { messages: [{ role: 'user', content: 'Hello' }] };

  describe('Opus 4.6 Adaptive Thinking', () => {
    it('sends thinking.type=adaptive for claude-opus-4-6 when thinking enabled', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, { enableThinking: true });
      expect(lastStreamParams.thinking).toEqual({ type: 'adaptive' });
    });

    it('does NOT send budget_tokens for claude-opus-4-6', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, { enableThinking: true, thinkingBudget: 5000 });
      expect(lastStreamParams.thinking).toEqual({ type: 'adaptive' });
      expect(lastStreamParams.thinking.budget_tokens).toBeUndefined();
    });

    // REGRESSION
    it('sends thinking.type=enabled with budget_tokens for claude-opus-4-5 (regression)', async () => {
      const provider = createApiKeyProvider('claude-opus-4-5-20251101');
      await collectStream(provider, ctx, { enableThinking: true, thinkingBudget: 5000 });
      expect(lastStreamParams.thinking).toEqual({ type: 'enabled', budget_tokens: 5000 });
    });

    it('sends thinking.type=enabled with budget_tokens for claude-sonnet-4-5 (regression)', async () => {
      const provider = createApiKeyProvider('claude-sonnet-4-5-20250929');
      await collectStream(provider, ctx, { enableThinking: true, thinkingBudget: 3000 });
      expect(lastStreamParams.thinking).toEqual({ type: 'enabled', budget_tokens: 3000 });
    });
  });

  describe('Opus 4.6 Effort Parameter', () => {
    it('sends output_config.effort when model supports effort and effortLevel set', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, { enableThinking: true, effortLevel: 'high' });
      expect(lastStreamParams.output_config).toEqual({ effort: 'high' });
    });

    // REGRESSION
    it('does NOT send output_config.effort for claude-opus-4-5 (regression)', async () => {
      const provider = createApiKeyProvider('claude-opus-4-5-20251101');
      await collectStream(provider, ctx, { enableThinking: true, effortLevel: 'high' });
      expect(lastStreamParams.output_config).toBeUndefined();
    });

    it('does NOT send output_config.effort when effortLevel is undefined', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, { enableThinking: true });
      expect(lastStreamParams.output_config).toBeUndefined();
    });
  });

  describe('Per-Model Defaults', () => {
    it('defaults maxTokens to model maxOutput for claude-opus-4-6 (128000)', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, {});
      expect(lastStreamParams.max_tokens).toBe(128000);
    });

    it('defaults maxTokens to model maxOutput for claude-opus-4-5 (64000)', async () => {
      const provider = createApiKeyProvider('claude-opus-4-5-20251101');
      await collectStream(provider, ctx, {});
      expect(lastStreamParams.max_tokens).toBe(64000);
    });

    it('uses options.maxTokens over model default', async () => {
      const provider = createApiKeyProvider('claude-opus-4-6');
      await collectStream(provider, ctx, { maxTokens: 4096 });
      expect(lastStreamParams.max_tokens).toBe(4096);
    });

    it('defaults thinking budget to 25% of model maxOutput for non-adaptive models', async () => {
      const provider = createApiKeyProvider('claude-opus-4-5-20251101');
      await collectStream(provider, ctx, { enableThinking: true });
      // claude-opus-4-5 maxOutput = 64000 → 64000 / 4 = 16000
      expect(lastStreamParams.thinking).toEqual({ type: 'enabled', budget_tokens: 16000 });
    });

    it('uses options.thinkingBudget over derived default', async () => {
      const provider = createApiKeyProvider('claude-opus-4-5-20251101');
      await collectStream(provider, ctx, { enableThinking: true, thinkingBudget: 5000 });
      expect(lastStreamParams.thinking).toEqual({ type: 'enabled', budget_tokens: 5000 });
    });

    it('falls back to DEFAULT_MAX_OUTPUT_TOKENS for unknown models', async () => {
      const provider = createApiKeyProvider('claude-unknown-model');
      await collectStream(provider, ctx, {});
      expect(lastStreamParams.max_tokens).toBe(DEFAULT_MAX_OUTPUT_TOKENS);
    });
  });

  describe('Opus 4.6 Beta Headers', () => {
    it('sends only oauth-2025-04-20 for claude-opus-4-6 (OAuth)', () => {
      createOAuthProv('claude-opus-4-6');
      expect(lastConstructorArgs.defaultHeaders['anthropic-beta']).toBe('oauth-2025-04-20');
    });

    // REGRESSION
    it('sends all 3 beta headers for claude-opus-4-5 (OAuth, regression)', () => {
      createOAuthProv('claude-opus-4-5-20251101');
      expect(lastConstructorArgs.defaultHeaders['anthropic-beta']).toBe(
        'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14'
      );
    });

    it('sends all 3 beta headers for claude-sonnet-4-5 (OAuth, regression)', () => {
      createOAuthProv('claude-sonnet-4-5-20250929');
      expect(lastConstructorArgs.defaultHeaders['anthropic-beta']).toBe(
        'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14'
      );
    });
  });
});
