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

const logger = createLogger('anthropic');

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
  // Claude 4.5 models (latest - November 2025)
  'claude-opus-4-5-20251101': {
    name: 'Claude Opus 4.5',
    contextWindow: 200000,
    maxOutput: 16384,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  'claude-sonnet-4-5-20250929': {
    name: 'Claude Sonnet 4.5',
    contextWindow: 200000,
    maxOutput: 16384,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 4.1 models (August 2025)
  'claude-opus-4-1-20250805': {
    name: 'Claude Opus 4.1',
    contextWindow: 200000,
    maxOutput: 16384,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  // Claude 4 models (May 2025)
  'claude-opus-4-20250514': {
    name: 'Claude Opus 4',
    contextWindow: 200000,
    maxOutput: 8192,
    supportsThinking: true,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.075,
  },
  'claude-sonnet-4-20250514': {
    name: 'Claude Sonnet 4',
    contextWindow: 200000,
    maxOutput: 8192,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3.7 models (February 2025)
  'claude-3-7-sonnet-20250219': {
    name: 'Claude 3.7 Sonnet',
    contextWindow: 200000,
    maxOutput: 8192,
    supportsThinking: true,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.015,
  },
  // Claude 3.5 models
  'claude-3-5-haiku-20241022': {
    name: 'Claude 3.5 Haiku',
    contextWindow: 200000,
    maxOutput: 8192,
    supportsThinking: false,
    inputCostPer1k: 0.0008,
    outputCostPer1k: 0.004,
  },
} as const;

/** Default model for new sessions */
export const DEFAULT_MODEL = 'claude-opus-4-5-20251101' as ClaudeModelId;

export type ClaudeModelId = keyof typeof CLAUDE_MODELS;

// =============================================================================
// OAuth Constants
// =============================================================================

/**
 * Headers required for OAuth authentication with Anthropic API.
 * The oauth-2025-04-20 beta flag enables OAuth token support.
 */
const OAUTH_HEADERS = {
  'accept': 'application/json',
  'anthropic-dangerous-direct-browser-access': 'true',
  'anthropic-beta': 'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14',
};

/**
 * System prompt prefix required for OAuth authentication.
 * Anthropic requires this identity statement for OAuth-authenticated requests.
 */
export const OAUTH_SYSTEM_PROMPT_PREFIX = 'You are Claude Code, Anthropic\'s official CLI for Claude.';

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

  constructor(config: AnthropicConfig) {
    this.config = config;
    this.isOAuth = config.auth.type === 'oauth';

    // Initialize Anthropic client
    if (config.auth.type === 'api_key') {
      this.client = new Anthropic({
        apiKey: config.auth.apiKey,
        baseURL: config.baseURL,
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
        defaultHeaders: OAUTH_HEADERS,
      });
    }

    logger.info('Anthropic provider initialized', { model: config.model, isOAuth: this.isOAuth });
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
        defaultHeaders: OAUTH_HEADERS,
      });
    }
  }

  /**
   * Stream a response from Claude
   */
  async *stream(
    context: Context,
    options: StreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    await this.ensureValidTokens();

    const model = this.config.model;
    const maxTokens = options.maxTokens ?? this.config.maxTokens ?? 4096;

    logger.debug('Starting stream', {
      model,
      maxTokens,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
    });

    yield { type: 'start' };

    try {
      // Convert messages to Anthropic format
      const messages = this.convertMessages(context.messages);
      const tools = context.tools ? this.convertTools(context.tools) : undefined;

      // Build system prompt - OAuth requires structured format with Claude Code identity
      let systemParam: string | SystemPromptBlock[] | undefined;

      if (this.isOAuth) {
        // OAuth: Use structured array format with cache_control (required by Anthropic)
        const systemBlocks: SystemPromptBlock[] = [
          {
            type: 'text',
            text: OAUTH_SYSTEM_PROMPT_PREFIX,
            cache_control: { type: 'ephemeral' },
          },
        ];
        if (context.systemPrompt) {
          systemBlocks.push({
            type: 'text',
            text: context.systemPrompt,
            cache_control: { type: 'ephemeral' },
          });
        }
        systemParam = systemBlocks;
      } else {
        // API key: Use simple string format
        systemParam = context.systemPrompt;
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
          budget_tokens: options.thinkingBudget ?? 2048,
        };
      }

      // Add stop sequences if provided
      if (options.stopSequences?.length) {
        params.stop_sequences = options.stopSequences;
      }

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
            if ('message' in event && event.message?.usage) {
              const usage = event.message.usage as {
                input_tokens?: number;
                cache_creation_input_tokens?: number;
                cache_read_input_tokens?: number;
              };
              inputTokens = usage.input_tokens ?? 0;
              cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
              cacheReadTokens = usage.cache_read_input_tokens ?? 0;
            }
            break;

          case 'message_delta':
            // Capture output tokens from message_delta
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
    } catch (error) {
      const parsed = parseError(error);
      const friendlyMessage = formatError(error);
      logger.error('Stream error', {
        category: parsed.category,
        message: parsed.message,
        isRetryable: parsed.isRetryable,
        rawError: error instanceof Error ? error.message : String(error),
      });
      // Create error with user-friendly message but preserve original error info
      const streamError = new Error(friendlyMessage);
      if (error instanceof Error) {
        streamError.cause = error;
      }
      yield { type: 'error', error: streamError };
    }
  }

  /**
   * Convert Tron messages to Anthropic format
   */
  private convertMessages(
    messages: Message[]
  ): Anthropic.Messages.MessageParam[] {
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
                return { type: 'text' as const, text: '' };
              });
          return { role: 'user' as const, content };
        }

        if (msg.role === 'assistant') {
          const content = msg.content.map((c) => {
            if (c.type === 'text') return { type: 'text' as const, text: c.text };
            if (c.type === 'tool_use') {
              return {
                type: 'tool_use' as const,
                id: c.id,
                name: c.name,
                input: c.arguments,
              };
            }
            return { type: 'text' as const, text: '' };
          });
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
              tool_use_id: msg.toolCallId,
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
      if (block.type === 'text') {
        content.push({ type: 'text', text: block.text });
      } else if (block.type === 'tool_use') {
        content.push({
          type: 'tool_use',
          id: block.id,
          name: block.name,
          arguments: block.input as Record<string, unknown>,
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
