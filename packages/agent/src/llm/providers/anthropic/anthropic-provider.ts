/**
 * @fileoverview Anthropic Claude Provider
 *
 * Core provider implementation for Claude models with:
 * - API key and OAuth authentication
 * - Extended thinking support
 * - Tool calling
 * - Streaming with automatic retry
 * - Prompt caching (OAuth)
 */

import Anthropic from '@anthropic-ai/sdk';
import type {
  Context,
  StreamEvent,
} from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import type { OAuthTokens } from '@infrastructure/auth/oauth.js';
import { getOAuthHeaders, ensureValidTokens } from './auth.js';
import { withProviderRetry, type StreamRetryConfig } from '../base/stream-retry.js';
import { sanitizeMessages } from '@core/utils/message-sanitizer.js';
import type { AnthropicConfig, StreamOptions, SystemPromptBlock, AnthropicProviderSettings } from './types.js';
import { CLAUDE_MODELS } from './types.js';
import { convertMessages, convertTools } from './message-converter.js';
import { processAnthropicStream, createStreamState } from './stream-handler.js';
import { DEFAULT_MAX_OUTPUT_TOKENS } from '@runtime/constants.js';
import { composeContextParts } from '../base/context-composition.js';

const logger = createLogger('anthropic');

// =============================================================================
// Provider Class
// =============================================================================

export class AnthropicProvider {
  private client: Anthropic;
  private config: AnthropicConfig;
  private tokens?: OAuthTokens;
  private isOAuth: boolean;
  private retryConfig: StreamRetryConfig;
  private providerSettings: AnthropicProviderSettings;

  constructor(config: AnthropicConfig) {
    this.config = config;
    if (!config.providerSettings) {
      throw new Error('AnthropicProvider requires providerSettings in config');
    }
    this.providerSettings = config.providerSettings;
    this.isOAuth = config.auth.type === 'oauth';
    this.retryConfig = {
      maxRetries: this.providerSettings.retry.maxRetries,
      baseDelayMs: this.providerSettings.retry.baseDelayMs,
      maxDelayMs: this.providerSettings.retry.maxDelayMs,
      jitterFactor: this.providerSettings.retry.jitterFactor,
      ...config.retry,
    };

    // SDK maxRetries: Use a low value since we handle retries ourselves with better backoff
    const sdkMaxRetries = 2;

    // Initialize Anthropic client
    if (config.auth.type === 'api_key') {
      this.client = new Anthropic({
        apiKey: config.auth.apiKey,
        baseURL: config.baseURL,
        maxRetries: sdkMaxRetries,
      });
    } else {
      this.tokens = {
        accessToken: config.auth.accessToken,
        refreshToken: config.auth.refreshToken,
        expiresAt: config.auth.expiresAt,
      };
      this.client = new Anthropic({
        apiKey: null as unknown as string,
        authToken: config.auth.accessToken,
        baseURL: config.baseURL,
        dangerouslyAllowBrowser: true,
        defaultHeaders: getOAuthHeaders(config.model, this.providerSettings),
        maxRetries: sdkMaxRetries,
      });
    }

    logger.info('Anthropic provider initialized', {
      model: config.model,
      isOAuth: this.isOAuth,
      retryConfig: this.retryConfig,
    });
  }

  get usingOAuth(): boolean {
    return this.isOAuth;
  }

  get model(): string {
    return this.config.model;
  }

  private async refreshTokensIfNeeded(): Promise<void> {
    if (!this.tokens) return;

    const accountLabel = this.config.auth.type === 'oauth' ? this.config.auth.accountLabel : undefined;
    const result = await ensureValidTokens(this.tokens, { accountLabel });

    if (result.refreshed) {
      this.tokens = result.tokens;
      this.client = new Anthropic({
        apiKey: null as unknown as string,
        authToken: this.tokens.accessToken,
        baseURL: this.config.baseURL,
        dangerouslyAllowBrowser: true,
        defaultHeaders: getOAuthHeaders(this.config.model, this.providerSettings),
      });
    }
  }

  /**
   * Stream a response from Anthropic with automatic retry on transient failures
   */
  async *stream(
    context: Context,
    options: StreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    await this.refreshTokensIfNeeded();

    yield { type: 'start' };

    yield* withProviderRetry(
      () => this.streamInternal(context, options),
      this.retryConfig
    );
  }

  /**
   * Internal stream implementation (called by retry wrapper)
   */
  private async *streamInternal(
    context: Context,
    options: StreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    const model = this.config.model;
    const modelInfo = CLAUDE_MODELS[model];
    const maxTokens = options.maxTokens ?? this.config.maxTokens ?? modelInfo?.maxOutput ?? DEFAULT_MAX_OUTPUT_TOKENS;

    logger.debug('Starting stream', {
      model,
      maxTokens,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
    });

    // Sanitize messages to guarantee API compliance (handles interrupted tool calls, etc.)
    const sanitized = sanitizeMessages(context.messages);
    const messages = convertMessages(sanitized.messages);
    const tools = context.tools ? convertTools(context.tools) : undefined;

    // Build system prompt
    const systemParam = this.buildSystemPrompt(context);

    // Build request parameters
    const params: Anthropic.Messages.MessageCreateParams = {
      model,
      max_tokens: maxTokens,
      messages,
      system: systemParam,
      tools,
    };

    // Add thinking if enabled
    if (options.enableThinking) {
      if (modelInfo?.supportsAdaptiveThinking) {
        params.thinking = { type: 'adaptive' };
      } else {
        params.thinking = {
          type: 'enabled',
          budget_tokens: options.thinkingBudget ?? Math.floor((modelInfo?.maxOutput ?? DEFAULT_MAX_OUTPUT_TOKENS) / 4),
        };
      }

      // Add effort parameter for models that support it
      if (modelInfo?.supportsEffort && options.effortLevel) {
        params.output_config = { effort: options.effortLevel as 'low' | 'medium' | 'high' | 'max' };
      }
    }

    if (options.stopSequences?.length) {
      params.stop_sequences = options.stopSequences;
    }

    const sdkStream = this.client.messages.stream(params);
    const state = createStreamState();
    yield* processAnthropicStream(sdkStream as any, state);
  }

  private buildSystemPrompt(context: Context): string | SystemPromptBlock[] | undefined {
    logger.info('[ANTHROPIC] Building system prompt', {
      isOAuth: this.isOAuth,
      hasSystemPrompt: !!context.systemPrompt,
      hasRulesContent: !!context.rulesContent,
      hasMemoryContent: !!context.memoryContent,
    });

    const parts = composeContextParts(context);

    if (this.isOAuth) {
      const systemBlocks: SystemPromptBlock[] = [
        { type: 'text', text: this.providerSettings.api.systemPromptPrefix },
        ...parts.map(text => ({ type: 'text' as const, text })),
      ];

      // Add cache control to last block
      const lastBlock = systemBlocks[systemBlocks.length - 1];
      if (lastBlock) {
        lastBlock.cache_control = { type: 'ephemeral' };
      }

      return systemBlocks;
    } else {
      return parts.length > 0 ? parts.join('\n\n') : undefined;
    }
  }

}
