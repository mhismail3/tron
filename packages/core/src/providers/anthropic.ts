/**
 * @fileoverview Anthropic Claude provider
 *
 * Provides streaming support for Claude models with:
 * - API key and OAuth authentication
 * - Extended thinking support
 * - Tool calling
 * - Automatic token refresh
 */

import Anthropic from '@anthropic-ai/sdk';
import type {
  Message,
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ThinkingContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { shouldRefreshTokens, refreshOAuthToken, type OAuthTokens } from '../auth/oauth.js';
import { parseError, formatError } from '../utils/errors.js';
import { calculateBackoffDelay, type RetryConfig } from '../utils/retry.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('anthropic');

// Get settings (loaded lazily on first access)
function getAnthropicSettings() {
  const settings = getSettings();
  return {
    api: settings.api.anthropic,
    models: settings.models,
    retry: settings.retry,
  };
}

// =============================================================================
// Types
// =============================================================================

/**
 * Authentication options for Anthropic
 */
export type AnthropicAuth =
  | { type: 'api_key'; apiKey: string }
  | { type: 'oauth'; accessToken: string; refreshToken: string; expiresAt: number };

/**
 * Configuration for Anthropic provider
 */
export interface AnthropicConfig {
  model: string;
  auth: AnthropicAuth;
  maxTokens?: number;
  temperature?: number;
  thinkingBudget?: number;
  baseURL?: string;
  /** Retry configuration for rate limits and transient errors */
  retry?: RetryConfig;
}

// =============================================================================
// Retry Defaults
// =============================================================================

/** Get default retry configuration from settings */
function getDefaultRetryConfig(): Required<Omit<RetryConfig, 'onRetry' | 'signal'>> {
  const { retry } = getAnthropicSettings();
  return {
    maxRetries: retry.maxRetries,
    baseDelayMs: retry.baseDelayMs,
    maxDelayMs: retry.maxDelayMs,
    jitterFactor: retry.jitterFactor,
  };
}

/**
 * Options for streaming requests
 */
export interface StreamOptions {
  maxTokens?: number;
  temperature?: number;
  enableThinking?: boolean;
  thinkingBudget?: number;
  stopSequences?: string[];
}

// =============================================================================
// Model Constants
// =============================================================================

export const CLAUDE_MODELS = {
  // Claude 4.5 models (latest - Current Generation)
  // Source: https://platform.claude.com/docs/en/about-claude/models/overview
  'claude-opus-4-5-20251101': {
    name: 'Claude Opus 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.005,  // $5 per million = $0.005 per 1K
    outputCostPer1k: 0.025, // $25 per million = $0.025 per 1K
  },
  'claude-sonnet-4-5-20250929': {
    name: 'Claude Sonnet 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,  // $3 per million
    outputCostPer1k: 0.015, // $15 per million
  },
  'claude-haiku-4-5-20251001': {
    name: 'Claude Haiku 4.5',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.001,  // $1 per million
    outputCostPer1k: 0.005, // $5 per million
  },
  // Claude 4.1 models (Legacy - August 2025)
  'claude-opus-4-1-20250805': {
    name: 'Claude Opus 4.1',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  // Claude 4 models (Legacy - May 2025)
  'claude-opus-4-20250514': {
    name: 'Claude Opus 4',
    contextWindow: 200000,
    maxOutput: 32000,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  'claude-sonnet-4-20250514': {
    name: 'Claude Sonnet 4',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3.7 models (Legacy - February 2025)
  'claude-3-7-sonnet-20250219': {
    name: 'Claude 3.7 Sonnet',
    contextWindow: 200000,
    maxOutput: 64000,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3 Haiku (Legacy - oldest still available)
  'claude-3-haiku-20240307': {
    name: 'Claude 3 Haiku',
    contextWindow: 200000,
    maxOutput: 4000,
    supportsThinking: false,
    inputCostPer1k: 0.00025, // $0.25 per million
    outputCostPer1k: 0.00125, // $1.25 per million
  },
} as const;

/** Get default model from settings */
export function getDefaultModel(): ClaudeModelId {
  const { models } = getAnthropicSettings();
  return models.default as ClaudeModelId;
}

/** Default model for new sessions (for backwards compatibility) */
export const DEFAULT_MODEL = 'claude-opus-4-5-20251101' as ClaudeModelId;

export type ClaudeModelId = keyof typeof CLAUDE_MODELS;

// =============================================================================
// OAuth Constants
// =============================================================================

/**
 * Get OAuth headers from settings
 */
function getOAuthHeaders() {
  const { api } = getAnthropicSettings();
  return {
    'accept': 'application/json',
    'anthropic-dangerous-direct-browser-access': 'true',
    'anthropic-beta': api.oauthBetaHeaders,
  };
}

/**
 * Get system prompt prefix from settings
 */
export function getOAuthSystemPromptPrefix(): string {
  const { api } = getAnthropicSettings();
  return api.systemPromptPrefix;
}

/**
 * System prompt prefix required for OAuth authentication.
 * Anthropic requires this identity statement for OAuth-authenticated requests.
 * @deprecated Use getOAuthSystemPromptPrefix() instead
 */
export const OAUTH_SYSTEM_PROMPT_PREFIX = "You are Claude Code, Anthropic's official CLI for Claude.";

/**
 * System prompt content block type for OAuth (uses cache control)
 */
type SystemPromptBlock = {
  type: 'text';
  text: string;
  cache_control?: { type: 'ephemeral' };
};

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
    // This prevents double-retry and gives us control over the retry strategy
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
      // OAuth requires: authToken, apiKey=null, and special beta headers
      this.client = new Anthropic({
        apiKey: null as unknown as string, // Must be null for OAuth
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

  /**
   * Check if this provider is using OAuth authentication
   */
  get usingOAuth(): boolean {
    return this.isOAuth;
  }

  /**
   * Get the current model ID
   */
  get model(): string {
    return this.config.model;
  }

  /**
   * Ensure tokens are valid, refresh if needed
   */
  private async ensureValidTokens(): Promise<void> {
    if (!this.tokens) return; // API key auth

    if (shouldRefreshTokens(this.tokens)) {
      logger.info('Refreshing expired OAuth tokens');
      this.tokens = await refreshOAuthToken(this.tokens.refreshToken);

      // Recreate client with new token (OAuth requires special config)
      this.client = new Anthropic({
        apiKey: null as unknown as string,
        authToken: this.tokens.accessToken,
        baseURL: this.config.baseURL,
        dangerouslyAllowBrowser: true,
        defaultHeaders: getOAuthHeaders(),
      });
    }
  }

  /**
   * Stream a response from Claude with automatic retry for rate limits
   *
   * Implements exponential backoff with jitter for retryable errors.
   * Only retries if no data has been yielded yet (can't retry partial streams).
   */
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

    // Convert messages to Anthropic format (done once, reused across retries)
    const messages = this.convertMessages(context.messages);
    const tools = context.tools ? this.convertTools(context.tools) : undefined;

    // Build system prompt - OAuth requires structured format with Claude Code identity
    let systemParam: string | SystemPromptBlock[] | undefined;

    logger.info('[ANTHROPIC] Building system prompt', {
      isOAuth: this.isOAuth,
      hasSystemPrompt: !!context.systemPrompt,
      hasRulesContent: !!context.rulesContent,
      rulesContentLength: context.rulesContent?.length ?? 0,
      hasSkillContext: !!context.skillContext,
      skillContextLength: context.skillContext?.length ?? 0,
    });

    if (this.isOAuth) {
      // OAuth: Use structured array format with cache_control for prompt caching
      //
      // Cache strategy:
      // 1. Build system blocks: OAuth prefix + system prompt + rules + skill context
      // 2. Put cache_control on the LAST block to cache the entire system prompt
      // 3. When skill context changes (added/removed), cache auto-invalidates
      //    and a new cache is created - no worse than not caching at all
      //
      // Anthropic requires minimum 1024 tokens for caching to take effect.
      // The cache_control marks the end of the cached prefix.

      const systemBlocks: SystemPromptBlock[] = [];

      // Block 1: OAuth prefix (required, small - ~12 tokens)
      // No cache_control here - too small to cache alone
      systemBlocks.push({
        type: 'text',
        text: getOAuthSystemPromptPrefix(),
      });

      // Block 2: System prompt (TRON core prompt, ~500-1000 tokens)
      if (context.systemPrompt) {
        systemBlocks.push({
          type: 'text',
          text: context.systemPrompt,
        });
      }

      // Block 3: Rules content (AGENTS.md/CLAUDE.md, static for session)
      // This is often the largest block and makes caching worthwhile
      if (context.rulesContent) {
        systemBlocks.push({
          type: 'text',
          text: `# Project Rules\n\n${context.rulesContent}`,
        });
      }

      // Block 4: Skill context (persists until manually removed from context)
      // Include in cached portion - cache will auto-invalidate when skill changes
      if (context.skillContext) {
        systemBlocks.push({
          type: 'text',
          text: context.skillContext,
        });
      }

      // Block 5: Sub-agent results context (ephemeral, injected once then cleared)
      // NOT cached - this is dynamic per-turn content about completed sub-agents
      if (context.subagentResultsContext) {
        systemBlocks.push({
          type: 'text',
          text: context.subagentResultsContext,
        });
      }

      // Block 6: Todo context (ephemeral, shows current task list)
      // NOT cached - this is dynamic per-turn content that changes frequently
      if (context.todoContext) {
        systemBlocks.push({
          type: 'text',
          text: `<current-todos>\n${context.todoContext}\n</current-todos>`,
        });
      }

      // =======================================================================
      // PROMPT CACHING FOR OAUTH
      // =======================================================================
      //
      // How Anthropic prompt caching works:
      // 1. Add cache_control: { type: 'ephemeral' } to mark cache breakpoints
      // 2. Anthropic caches everything FROM THE START up to each breakpoint
      // 3. Request order: tools → system → messages
      // 4. Subsequent requests with identical content get cache READS (90% cheaper)
      //
      // Minimum token thresholds (content up to breakpoint):
      // - Claude Opus 4.5: ~4096 tokens (discovered empirically)
      // - Claude Sonnet: 1024 tokens (documented)
      // - Claude Haiku: 2048 tokens (documented)
      //
      // Our strategy: Mark the LAST system block with cache_control
      // This caches: all tools + all system blocks = typically 4000+ tokens
      //
      // When skills change, the cache auto-invalidates and a new cache is
      // created on the next request - same cost as not caching at all.
      // =======================================================================
      const lastBlock = systemBlocks[systemBlocks.length - 1];
      if (lastBlock) {
        lastBlock.cache_control = { type: 'ephemeral' };
      }

      // Calculate approximate token count for system blocks only
      const cachedTokenEstimate = systemBlocks
        .reduce((acc, b) => acc + Math.ceil(b.text.length / 4), 0);

      logger.info('[ANTHROPIC] System blocks ready', {
        blockCount: systemBlocks.length,
        hasSkillContext: !!context.skillContext,
        estimatedCachedTokens: cachedTokenEstimate,
        cacheThresholdMet: cachedTokenEstimate >= 1024,
      });

      systemParam = systemBlocks;
    } else {
      // API key: Combine system prompt, rules, skill context, subagent results, and todo context into single string
      // (No caching for API key auth - only OAuth supports prompt caching)
      const parts: string[] = [];
      if (context.systemPrompt) parts.push(context.systemPrompt);
      if (context.rulesContent) parts.push(`# Project Rules\n\n${context.rulesContent}`);
      if (context.skillContext) parts.push(context.skillContext);
      if (context.subagentResultsContext) parts.push(context.subagentResultsContext);
      if (context.todoContext) parts.push(`<current-todos>\n${context.todoContext}\n</current-todos>`);
      systemParam = parts.length > 0 ? parts.join('\n\n') : undefined;
    }

    // =======================================================================
    // CACHE TOKEN ESTIMATION
    // =======================================================================
    // Estimate total cached tokens (tools + system) for threshold check.
    // The cache breakpoint on the last system block caches everything before it,
    // including all tool definitions.
    //
    // Token estimation: chars/4 + 15% overhead for tokenization metadata
    // (JSON structure, parameter names, etc. add extra tokens)
    // =======================================================================
    const toolTokenEstimate = tools
      ? tools.reduce((acc, t) => acc + Math.ceil((t.description?.length ?? 0) / 4) + Math.ceil(JSON.stringify(t.input_schema ?? {}).length / 4), 0)
      : 0;
    const systemTokenEstimate = Array.isArray(systemParam)
      ? systemParam.reduce((acc, b) => acc + Math.ceil(b.text.length / 4), 0)
      : 0;

    if (this.isOAuth) {
      // Apply 15% overhead factor - actual tokens are higher due to tokenization
      const adjustedEstimate = Math.ceil((toolTokenEstimate + systemTokenEstimate) * 1.15);
      logger.info('[CACHE] Request summary', {
        toolTokens: toolTokenEstimate,
        systemTokens: systemTokenEstimate,
        rawEstimate: toolTokenEstimate + systemTokenEstimate,
        adjustedEstimate,
        threshold: 4096,  // Opus requires ~4096 tokens minimum for caching
        meetsThreshold: adjustedEstimate >= 4096,
      });
    }

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

    // Add stop sequences if provided
    if (options.stopSequences?.length) {
      params.stop_sequences = options.stopSequences;
    }

    // Retry loop with exponential backoff
    let attempt = 0;
    let hasYieldedData = false;

    while (attempt <= this.retryConfig.maxRetries) {
      try {
        // Stream the response
        const stream = this.client.messages.stream(params);

        let currentBlockType: 'text' | 'thinking' | 'tool_use' | null = null;
        let currentToolCallId: string | null = null;
        let currentToolName: string | null = null;
        let accumulatedText = '';
        let accumulatedThinking = '';
        let accumulatedArgs = '';

        // Track usage from streaming events (more reliable than finalMessage)
        let inputTokens = 0;
        let outputTokens = 0;
        let cacheCreationTokens = 0;
        let cacheReadTokens = 0;

        for await (const event of stream) {
          switch (event.type) {
            case 'message_start':
              // Capture input and cache tokens from message_start
              hasYieldedData = true; // Mark that we've received data
              if ('message' in event && event.message?.usage) {
                const usage = event.message.usage as {
                  input_tokens?: number;
                  cache_creation_input_tokens?: number;
                  cache_read_input_tokens?: number;
                };
                // Log raw usage for cache debugging
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
              // Trace log for stream debugging
              logger.trace('Stream: message_start', {
                messageId: ('message' in event && event.message?.id) || undefined,
                model: ('message' in event && event.message?.model) || undefined,
                inputTokens,
              });
              break;

            case 'message_delta':
              // Capture output tokens from message_delta
              if ('usage' in event && event.usage) {
                outputTokens = (event.usage as { output_tokens?: number }).output_tokens ?? 0;
              }
              // Trace log for stream debugging
              logger.trace('Stream: message_delta', {
                outputTokens,
                stopReason: ('delta' in event && (event.delta as { stop_reason?: string })?.stop_reason) || undefined,
              });
              break;

            case 'content_block_start':
              // Trace log for stream debugging
              logger.trace('Stream: content_block_start', {
                index: event.index,
                type: event.content_block.type,
                toolName: event.content_block.type === 'tool_use' ? event.content_block.name : undefined,
              });
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
                yield { type: 'thinking_end', thinking: accumulatedThinking };
                accumulatedThinking = '';
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
              // Get final message - wrap in try/catch as finalMessage() can throw
              try {
                const finalMessage = await stream.finalMessage();
                if (finalMessage) {
                  const assistantMessage = this.convertResponse(finalMessage);
                  // Override usage with streamed values if they're more complete
                  if (inputTokens > 0 || outputTokens > 0) {
                    assistantMessage.usage = {
                      inputTokens: inputTokens || assistantMessage.usage?.inputTokens || 0,
                      outputTokens: outputTokens || assistantMessage.usage?.outputTokens || 0,
                      cacheCreationTokens: cacheCreationTokens || assistantMessage.usage?.cacheCreationTokens,
                      cacheReadTokens: cacheReadTokens || assistantMessage.usage?.cacheReadTokens,
                    };
                  }
                  yield {
                    type: 'done',
                    message: assistantMessage,
                    stopReason: finalMessage.stop_reason ?? 'end_turn',
                  };
                } else {
                  // If no final message, emit done with accumulated content and streamed usage
                  yield {
                    type: 'done',
                    message: {
                      role: 'assistant' as const,
                      content: [],
                      usage: { inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens },
                    },
                    stopReason: 'end_turn',
                  };
                }
              } catch (err) {
                const errMsg = err instanceof Error ? err.message : String(err);
                logger.warn('Could not get final message', { error: errMsg });
                // Use streamed usage values in fallback
                yield {
                  type: 'done',
                  message: {
                    role: 'assistant' as const,
                    content: [],
                    usage: { inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens },
                  },
                  stopReason: 'end_turn',
                };
              }
              break;
          }
        }

        // Stream completed successfully
        return;
      } catch (error) {
        attempt++;
        const parsed = parseError(error);

        // Trace log full error details for debugging
        logger.trace('Anthropic stream error - full details', {
          errorCategory: parsed.category,
          errorMessage: parsed.message,
          isRetryable: parsed.isRetryable,
          attempt,
          hasYieldedData,
          fullError: error instanceof Error ? {
            name: error.name,
            message: error.message,
            stack: error.stack,
            cause: error.cause,
          } : error,
          requestContext: {
            model: this.config.model,
            messageCount: context.messages.length,
            hasTools: !!context.tools?.length,
          },
        });

        // If we've already yielded data, we can't retry (partial stream)
        // The consumer has already received some events
        if (hasYieldedData) {
          logger.error('Stream error after partial data, cannot retry', {
            category: parsed.category,
            message: parsed.message,
            attempt,
          });
          const streamError = new Error(formatError(error));
          if (error instanceof Error) {
            streamError.cause = error;
          }
          yield { type: 'error', error: streamError };
          return;
        }

        // Don't retry non-retryable errors
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

        // Check if we've exhausted retries
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

        // Calculate delay with exponential backoff and jitter
        const delayMs = calculateBackoffDelay(
          attempt - 1,
          this.retryConfig.baseDelayMs,
          this.retryConfig.maxDelayMs,
          this.retryConfig.jitterFactor
        );

        // Check for retry-after header
        const retryAfter = this.extractRetryAfter(error);
        const actualDelay = retryAfter !== null ? Math.max(delayMs, retryAfter) : delayMs;

        logger.info('Retrying stream after error', {
          category: parsed.category,
          message: parsed.message,
          attempt,
          maxRetries: this.retryConfig.maxRetries,
          delayMs: actualDelay,
        });

        // Emit retry event so TUI can show status
        yield {
          type: 'retry',
          attempt,
          maxRetries: this.retryConfig.maxRetries,
          delayMs: actualDelay,
          error: parsed,
        } as StreamEvent;

        // Wait before retry
        await this.sleep(actualDelay);
      }
    }
  }

  /**
   * Extract retry-after header value from an error
   */
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

    // Try parsing as number of seconds
    const seconds = parseInt(value, 10);
    if (!isNaN(seconds)) {
      return seconds * 1000;
    }

    // Try parsing as HTTP date
    const date = new Date(value);
    if (!isNaN(date.getTime())) {
      const delayMs = date.getTime() - Date.now();
      return delayMs > 0 ? delayMs : 0;
    }

    return null;
  }

  /**
   * Sleep for specified duration
   */
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Convert Tron messages to Anthropic format
   *
   * Note: Tool call IDs from other providers (e.g., OpenAI's `call_` prefix)
   * are remapped to Anthropic-compatible format to support mid-session provider switching.
   */
  private convertMessages(
    messages: Message[]
  ): Anthropic.Messages.MessageParam[] {
    // Build a mapping of original tool call IDs to normalized IDs.
    // This is necessary when switching providers mid-session, as tool call IDs
    // from other providers (e.g., OpenAI's `call_...`) may not be recognized.
    // Only remap IDs that don't already look like Anthropic format.
    const idMapping = new Map<string, string>();
    let idCounter = 0;

    // First pass: collect tool call IDs that need remapping (non-Anthropic format)
    for (const msg of messages) {
      if (msg.role === 'assistant') {
        const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
        for (const tc of toolUses) {
          // Only remap IDs that don't look like Anthropic format (toolu_*)
          if (!idMapping.has(tc.id) && !tc.id.startsWith('toolu_')) {
            idMapping.set(tc.id, `toolu_remap_${idCounter++}`);
          }
        }
      }
    }

    return messages
      .filter((msg): msg is Message => msg.role !== 'toolResult' || !!msg.toolCallId)
      .map((msg) => {
        if (msg.role === 'user') {
          const content = typeof msg.content === 'string'
            ? msg.content
            : msg.content.map((c) => {
                if (c.type === 'text') return { type: 'text' as const, text: c.text };
                if (c.type === 'image') {
                  return {
                    type: 'image' as const,
                    source: {
                      type: 'base64' as const,
                      media_type: c.mimeType as 'image/jpeg' | 'image/png' | 'image/gif' | 'image/webp',
                      data: c.data,
                    },
                  };
                }
                if (c.type === 'document') {
                  return {
                    type: 'document' as const,
                    source: {
                      type: 'base64' as const,
                      media_type: c.mimeType as 'application/pdf',
                      data: c.data,
                    },
                  };
                }
                // Handle tool_result content blocks stored in message.user events
                // (created at turn end for proper sequencing after message.assistant)
                // Note: These come from event store reconstruction, not the TypeScript type system
                const maybeToolResult = c as { type: string; tool_use_id?: string; content?: string; is_error?: boolean };
                if (maybeToolResult.type === 'tool_result') {
                  return {
                    type: 'tool_result' as const,
                    tool_use_id: idMapping.get(maybeToolResult.tool_use_id!) ?? maybeToolResult.tool_use_id!,
                    content: maybeToolResult.content,
                    is_error: maybeToolResult.is_error,
                  };
                }
                return { type: 'text' as const, text: '' };
              });
          return { role: 'user' as const, content };
        }

        if (msg.role === 'assistant') {
          // Map content blocks, filtering out thinking blocks
          // CRITICAL: Anthropic API requires that thinking content NOT be sent back
          // in subsequent turns - thinking is ephemeral per-turn only
          const content = msg.content
            .map((c) => {
              if (c.type === 'text') return { type: 'text' as const, text: c.text };
              if (c.type === 'tool_use') {
                // Handle both 'arguments' (in-memory ToolCall type) and 'input' (persisted event format)
                const input = c.arguments ?? (c as any).input ?? {};
                return {
                  type: 'tool_use' as const,
                  id: idMapping.get(c.id) ?? c.id,
                  name: c.name,
                  input,
                };
              }
              // Skip thinking blocks - they must NOT be sent back to the API
              if (c.type === 'thinking') return null;
              // Unknown content type - skip rather than create empty text
              return null;
            })
            .filter((c): c is NonNullable<typeof c> => c !== null);
          return { role: 'assistant' as const, content };
        }

        if (msg.role === 'toolResult') {
          const content = typeof msg.content === 'string'
            ? msg.content
            : msg.content.map((c) => {
                if (c.type === 'text') return { type: 'text' as const, text: c.text };
                if (c.type === 'image') {
                  return {
                    type: 'image' as const,
                    source: {
                      type: 'base64' as const,
                      media_type: c.mimeType as 'image/jpeg' | 'image/png' | 'image/gif' | 'image/webp',
                      data: c.data,
                    },
                  };
                }
                return { type: 'text' as const, text: '' };
              });
          return {
            role: 'user' as const,
            content: [{
              type: 'tool_result' as const,
              tool_use_id: idMapping.get(msg.toolCallId) ?? msg.toolCallId,
              content,
              is_error: msg.isError,
            }],
          };
        }

        return { role: 'user' as const, content: '' };
      });
  }

  /**
   * Convert Tron tools to Anthropic format
   */
  private convertTools(
    tools: NonNullable<Context['tools']>
  ): Anthropic.Messages.Tool[] {
    return tools.map((tool) => ({
      name: tool.name,
      description: tool.description,
      input_schema: tool.parameters as Anthropic.Messages.Tool['input_schema'],
    }));
  }

  /**
   * Convert Anthropic response to Tron format
   */
  private convertResponse(
    response: Anthropic.Messages.Message
  ): AssistantMessage {
    const content: (TextContent | ThinkingContent | ToolCall)[] = [];

    // Handle case where response or content might be malformed
    if (!response) {
      return {
        role: 'assistant',
        content: [],
        usage: { inputTokens: 0, outputTokens: 0 },
      };
    }

    // Handle case where content might not be iterable
    const blocks = Array.isArray(response.content) ? response.content : [];
    for (const block of blocks) {
      // Cast to unknown first to handle thinking blocks which aren't in the base SDK types
      const blockType = (block as { type: string }).type;
      if (blockType === 'text') {
        content.push({ type: 'text', text: (block as { text: string }).text });
      } else if (blockType === 'thinking') {
        // Extract thinking content from extended thinking response
        content.push({
          type: 'thinking',
          thinking: (block as unknown as { thinking: string }).thinking,
        });
      } else if (blockType === 'tool_use') {
        const toolBlock = block as { id: string; name: string; input: unknown };
        content.push({
          type: 'tool_use',
          id: toolBlock.id,
          name: toolBlock.name,
          arguments: toolBlock.input as Record<string, unknown>,
        });
      }
    }

    // Extract cache tokens from usage (Anthropic's extended usage object)
    const usageWithCache = response.usage as {
      input_tokens?: number;
      output_tokens?: number;
      cache_creation_input_tokens?: number;
      cache_read_input_tokens?: number;
    } | undefined;

    return {
      role: 'assistant',
      content,
      usage: {
        inputTokens: usageWithCache?.input_tokens ?? 0,
        outputTokens: usageWithCache?.output_tokens ?? 0,
        cacheCreationTokens: usageWithCache?.cache_creation_input_tokens,
        cacheReadTokens: usageWithCache?.cache_read_input_tokens,
      },
      stopReason: response.stop_reason as AssistantMessage['stopReason'],
    };
  }
}
