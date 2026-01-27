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
  AssistantMessage,
  Context,
  StreamEvent,
  ToolCall,
} from '../../types/index.js';
import { createLogger } from '../../logging/index.js';
import { shouldRefreshTokens, refreshOAuthToken, type OAuthTokens } from '../../auth/oauth.js';
import { parseError, formatError } from '../../utils/errors.js';
import { calculateBackoffDelay, type RetryConfig } from '../../utils/retry.js';
import { getSettings } from '../../settings/index.js';
import type { AnthropicConfig, StreamOptions, SystemPromptBlock } from './types.js';
import { convertMessages, convertTools, convertResponse } from './message-converter.js';

const logger = createLogger('anthropic');

// =============================================================================
// Settings Helper
// =============================================================================

function getAnthropicSettings() {
  const settings = getSettings();
  return {
    api: settings.api.anthropic,
    models: settings.models,
    retry: settings.retry,
  };
}

function getDefaultRetryConfig(): Required<Omit<RetryConfig, 'onRetry' | 'signal'>> {
  const { retry } = getAnthropicSettings();
  return {
    maxRetries: retry.maxRetries,
    baseDelayMs: retry.baseDelayMs,
    maxDelayMs: retry.maxDelayMs,
    jitterFactor: retry.jitterFactor,
  };
}

function getOAuthHeaders() {
  const { api } = getAnthropicSettings();
  return {
    'accept': 'application/json',
    'anthropic-dangerous-direct-browser-access': 'true',
    'anthropic-beta': api.oauthBetaHeaders,
  };
}

export function getOAuthSystemPromptPrefix(): string {
  const { api } = getAnthropicSettings();
  return api.systemPromptPrefix;
}

export function getDefaultModel(): string {
  const { models } = getAnthropicSettings();
  return models.default;
}

// =============================================================================
// Provider Class
// =============================================================================

export class AnthropicProvider {
  private client: Anthropic;
  private config: AnthropicConfig;
  private tokens?: OAuthTokens;
  private isOAuth: boolean;
  private retryConfig: Required<Omit<RetryConfig, 'onRetry' | 'signal'>>;

  constructor(config: AnthropicConfig) {
    this.config = config;
    this.isOAuth = config.auth.type === 'oauth';
    this.retryConfig = {
      ...getDefaultRetryConfig(),
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
        defaultHeaders: getOAuthHeaders(),
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

  private async ensureValidTokens(): Promise<void> {
    if (!this.tokens) return;

    if (shouldRefreshTokens(this.tokens)) {
      logger.info('Refreshing expired OAuth tokens');
      this.tokens = await refreshOAuthToken(this.tokens.refreshToken);

      this.client = new Anthropic({
        apiKey: null as unknown as string,
        authToken: this.tokens.accessToken,
        baseURL: this.config.baseURL,
        dangerouslyAllowBrowser: true,
        defaultHeaders: getOAuthHeaders(),
      });
    }
  }

  async *stream(
    context: Context,
    options: StreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    await this.ensureValidTokens();

    const { models } = getAnthropicSettings();
    const model = this.config.model;
    const maxTokens = options.maxTokens ?? this.config.maxTokens ?? models.defaultMaxTokens;

    logger.debug('Starting stream', {
      model,
      maxTokens,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
    });

    yield { type: 'start' };

    const messages = convertMessages(context.messages);
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
      (params as unknown as { thinking: { type: string; budget_tokens: number } }).thinking = {
        type: 'enabled',
        budget_tokens: options.thinkingBudget ?? models.defaultThinkingBudget,
      };
    }

    if (options.stopSequences?.length) {
      params.stop_sequences = options.stopSequences;
    }

    // Retry loop with exponential backoff
    let attempt = 0;
    let hasYieldedData = false;

    while (attempt <= this.retryConfig.maxRetries) {
      try {
        const stream = this.client.messages.stream(params);

        let currentBlockType: 'text' | 'thinking' | 'tool_use' | null = null;
        let currentToolCallId: string | null = null;
        let currentToolName: string | null = null;
        let accumulatedText = '';
        let accumulatedThinking = '';
        let accumulatedSignature = '';
        let accumulatedArgs = '';

        let inputTokens = 0;
        let outputTokens = 0;
        let cacheCreationTokens = 0;
        let cacheReadTokens = 0;

        for await (const event of stream) {
          switch (event.type) {
            case 'message_start':
              hasYieldedData = true;
              if ('message' in event && event.message?.usage) {
                const usage = event.message.usage as {
                  input_tokens?: number;
                  cache_creation_input_tokens?: number;
                  cache_read_input_tokens?: number;
                };
                inputTokens = usage.input_tokens ?? 0;
                cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
                cacheReadTokens = usage.cache_read_input_tokens ?? 0;
                logger.info('[CACHE] API response', {
                  inputTokens,
                  cacheCreationTokens,
                  cacheReadTokens,
                  cacheHit: cacheReadTokens > 0,
                  cacheWrite: cacheCreationTokens > 0,
                });
              }
              break;

            case 'message_delta':
              if ('usage' in event && event.usage) {
                outputTokens = (event.usage as { output_tokens?: number }).output_tokens ?? 0;
              }
              break;

            case 'content_block_start':
              if (event.content_block.type === 'text') {
                currentBlockType = 'text';
                yield { type: 'text_start' };
              } else if (event.content_block.type === 'thinking') {
                currentBlockType = 'thinking';
                yield { type: 'thinking_start' };
              } else if (event.content_block.type === 'tool_use') {
                currentBlockType = 'tool_use';
                currentToolCallId = event.content_block.id;
                currentToolName = event.content_block.name;
                yield {
                  type: 'toolcall_start',
                  toolCallId: event.content_block.id,
                  name: event.content_block.name,
                };
              }
              break;

            case 'content_block_delta':
              if (event.delta.type === 'text_delta') {
                accumulatedText += event.delta.text;
                yield { type: 'text_delta', delta: event.delta.text };
              } else if (event.delta.type === 'thinking_delta') {
                accumulatedThinking += event.delta.thinking;
                yield { type: 'thinking_delta', delta: event.delta.thinking };
              } else if (event.delta.type === 'signature_delta') {
                accumulatedSignature += (event.delta as { signature: string }).signature;
              } else if (event.delta.type === 'input_json_delta') {
                accumulatedArgs += event.delta.partial_json;
                yield {
                  type: 'toolcall_delta',
                  toolCallId: currentToolCallId!,
                  argumentsDelta: event.delta.partial_json,
                };
              }
              break;

            case 'content_block_stop':
              if (currentBlockType === 'text') {
                yield { type: 'text_end', text: accumulatedText };
                accumulatedText = '';
              } else if (currentBlockType === 'thinking') {
                yield {
                  type: 'thinking_end',
                  thinking: accumulatedThinking,
                  ...(accumulatedSignature && { signature: accumulatedSignature }),
                };
                accumulatedThinking = '';
                accumulatedSignature = '';
              } else if (currentBlockType === 'tool_use') {
                const toolCall: ToolCall = {
                  type: 'tool_use',
                  id: currentToolCallId!,
                  name: currentToolName!,
                  arguments: JSON.parse(accumulatedArgs || '{}'),
                };
                yield { type: 'toolcall_end', toolCall };
                accumulatedArgs = '';
                currentToolCallId = null;
                currentToolName = null;
              }
              currentBlockType = null;
              break;

            case 'message_stop':
              try {
                const finalMessage = await stream.finalMessage();
                if (finalMessage) {
                  const assistantMessage = convertResponse(finalMessage);
                  if (inputTokens > 0 || outputTokens > 0) {
                    assistantMessage.usage = {
                      inputTokens: inputTokens || assistantMessage.usage?.inputTokens || 0,
                      outputTokens: outputTokens || assistantMessage.usage?.outputTokens || 0,
                      cacheCreationTokens: cacheCreationTokens || assistantMessage.usage?.cacheCreationTokens,
                      cacheReadTokens: cacheReadTokens || assistantMessage.usage?.cacheReadTokens,
                      providerType: 'anthropic' as const,
                    };
                  }
                  yield {
                    type: 'done',
                    message: assistantMessage as AssistantMessage,
                    stopReason: finalMessage.stop_reason ?? 'end_turn',
                  };
                } else {
                  yield {
                    type: 'done',
                    message: {
                      role: 'assistant' as const,
                      content: [],
                      usage: { inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, providerType: 'anthropic' as const },
                    },
                    stopReason: 'end_turn',
                  };
                }
              } catch (err) {
                const errMsg = err instanceof Error ? err.message : String(err);
                logger.warn('Could not get final message', { error: errMsg });
                yield {
                  type: 'done',
                  message: {
                    role: 'assistant' as const,
                    content: [],
                    usage: { inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, providerType: 'anthropic' as const },
                  },
                  stopReason: 'end_turn',
                };
              }
              break;
          }
        }

        return;
      } catch (error) {
        attempt++;
        const parsed = parseError(error);

        logger.trace('Anthropic stream error - full details', {
          errorCategory: parsed.category,
          errorMessage: parsed.message,
          isRetryable: parsed.isRetryable,
          attempt,
          hasYieldedData,
        });

        if (hasYieldedData) {
          logger.error('Stream error after partial data, cannot retry', {
            category: parsed.category,
            message: parsed.message,
          });
          const streamError = new Error(formatError(error));
          if (error instanceof Error) {
            streamError.cause = error;
          }
          yield { type: 'error', error: streamError };
          return;
        }

        if (!parsed.isRetryable) {
          logger.error('Non-retryable stream error', {
            category: parsed.category,
            message: parsed.message,
          });
          const streamError = new Error(formatError(error));
          if (error instanceof Error) {
            streamError.cause = error;
          }
          yield { type: 'error', error: streamError };
          return;
        }

        if (attempt > this.retryConfig.maxRetries) {
          logger.error('Stream max retries exhausted', {
            category: parsed.category,
            message: parsed.message,
            attempts: attempt,
          });
          const streamError = new Error(formatError(error));
          if (error instanceof Error) {
            streamError.cause = error;
          }
          yield { type: 'error', error: streamError };
          return;
        }

        const delayMs = calculateBackoffDelay(
          attempt - 1,
          this.retryConfig.baseDelayMs,
          this.retryConfig.maxDelayMs,
          this.retryConfig.jitterFactor
        );

        const retryAfter = this.extractRetryAfter(error);
        const actualDelay = retryAfter !== null ? Math.max(delayMs, retryAfter) : delayMs;

        logger.info('Retrying stream after error', {
          category: parsed.category,
          message: parsed.message,
          attempt,
          maxRetries: this.retryConfig.maxRetries,
          delayMs: actualDelay,
        });

        yield {
          type: 'retry',
          attempt,
          maxRetries: this.retryConfig.maxRetries,
          delayMs: actualDelay,
          error: parsed,
        } as StreamEvent;

        await this.sleep(actualDelay);
      }
    }
  }

  private buildSystemPrompt(context: Context): string | SystemPromptBlock[] | undefined {
    logger.info('[ANTHROPIC] Building system prompt', {
      isOAuth: this.isOAuth,
      hasSystemPrompt: !!context.systemPrompt,
      hasRulesContent: !!context.rulesContent,
    });

    if (this.isOAuth) {
      const systemBlocks: SystemPromptBlock[] = [];

      systemBlocks.push({
        type: 'text',
        text: getOAuthSystemPromptPrefix(),
      });

      if (context.systemPrompt) {
        systemBlocks.push({ type: 'text', text: context.systemPrompt });
      }

      if (context.rulesContent) {
        systemBlocks.push({
          type: 'text',
          text: `# Project Rules\n\n${context.rulesContent}`,
        });
      }

      if (context.skillContext) {
        systemBlocks.push({ type: 'text', text: context.skillContext });
      }

      if (context.subagentResultsContext) {
        systemBlocks.push({ type: 'text', text: context.subagentResultsContext });
      }

      if (context.todoContext) {
        systemBlocks.push({
          type: 'text',
          text: `<current-todos>\n${context.todoContext}\n</current-todos>`,
        });
      }

      // Add cache control to last block
      const lastBlock = systemBlocks[systemBlocks.length - 1];
      if (lastBlock) {
        lastBlock.cache_control = { type: 'ephemeral' };
      }

      return systemBlocks;
    } else {
      const parts: string[] = [];
      if (context.systemPrompt) parts.push(context.systemPrompt);
      if (context.rulesContent) parts.push(`# Project Rules\n\n${context.rulesContent}`);
      if (context.skillContext) parts.push(context.skillContext);
      if (context.subagentResultsContext) parts.push(context.subagentResultsContext);
      if (context.todoContext) parts.push(`<current-todos>\n${context.todoContext}\n</current-todos>`);
      return parts.length > 0 ? parts.join('\n\n') : undefined;
    }
  }

  private extractRetryAfter(error: unknown): number | null {
    if (!error || typeof error !== 'object') return null;

    const errorObj = error as {
      headers?: Record<string, string>;
      response?: { headers?: Record<string, string> };
    };

    const headers = errorObj.headers ?? errorObj.response?.headers;
    if (!headers) return null;

    const retryAfterKey = Object.keys(headers).find(
      (k) => k.toLowerCase() === 'retry-after'
    );
    if (!retryAfterKey) return null;

    const value = headers[retryAfterKey];
    if (!value) return null;

    const seconds = parseInt(value, 10);
    if (!isNaN(seconds)) {
      return seconds * 1000;
    }

    const date = new Date(value);
    if (!isNaN(date.getTime())) {
      const delayMs = date.getTime() - Date.now();
      return delayMs > 0 ? delayMs : 0;
    }

    return null;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
