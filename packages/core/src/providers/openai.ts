/**
 * @fileoverview OpenAI GPT Provider
 *
 * Provides streaming support for OpenAI models (GPT-4, GPT-4o, etc.) with:
 * - API key authentication
 * - Tool/function calling
 * - Streaming responses
 * - Compatible interface with Anthropic provider
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('openai');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for OpenAI provider
 */
export interface OpenAIConfig {
  model: string;
  apiKey: string;
  maxTokens?: number;
  temperature?: number;
  baseURL?: string;
  organization?: string;
}

/**
 * Options for streaming requests
 */
export interface OpenAIStreamOptions {
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  frequencyPenalty?: number;
  presencePenalty?: number;
  stopSequences?: string[];
}

/**
 * OpenAI API message format
 */
interface OpenAIMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | null;
  tool_calls?: OpenAIToolCall[];
  tool_call_id?: string;
  name?: string;
}

interface OpenAIToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string;
  };
}

interface OpenAITool {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

interface OpenAIStreamChunk {
  id: string;
  object: string;
  created: number;
  model: string;
  choices: Array<{
    index: number;
    delta: {
      role?: string;
      content?: string | null;
      tool_calls?: Array<{
        index: number;
        id?: string;
        type?: string;
        function?: {
          name?: string;
          arguments?: string;
        };
      }>;
    };
    finish_reason: string | null;
  }>;
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

// =============================================================================
// Model Constants
// =============================================================================

export const OPENAI_MODELS = {
  // GPT-4.1 series (April 2025 - latest)
  'gpt-4.1-2025-04-14': {
    name: 'GPT-4.1',
    contextWindow: 128000,
    maxOutput: 32768,
    supportsTools: true,
    inputCostPer1k: 0.005,
    outputCostPer1k: 0.015,
  },
  'gpt-4.1-mini-2025-04-14': {
    name: 'GPT-4.1 Mini',
    contextWindow: 128000,
    maxOutput: 32768,
    supportsTools: true,
    inputCostPer1k: 0.00015,
    outputCostPer1k: 0.0006,
  },
  'gpt-4.1-nano-2025-04-14': {
    name: 'GPT-4.1 Nano',
    contextWindow: 128000,
    maxOutput: 16384,
    supportsTools: true,
    inputCostPer1k: 0.0001,
    outputCostPer1k: 0.0004,
  },
  // GPT-4o series (still widely used)
  'gpt-4o-2024-11-20': {
    name: 'GPT-4o (Nov 2024)',
    contextWindow: 128000,
    maxOutput: 16384,
    supportsTools: true,
    inputCostPer1k: 0.005,
    outputCostPer1k: 0.015,
  },
  'gpt-4o': {
    name: 'GPT-4o',
    contextWindow: 128000,
    maxOutput: 16384,
    supportsTools: true,
    inputCostPer1k: 0.005,
    outputCostPer1k: 0.015,
  },
  'gpt-4o-mini': {
    name: 'GPT-4o Mini',
    contextWindow: 128000,
    maxOutput: 16384,
    supportsTools: true,
    inputCostPer1k: 0.00015,
    outputCostPer1k: 0.0006,
  },
  // o-series reasoning models
  'o1': {
    name: 'o1',
    contextWindow: 200000,
    maxOutput: 100000,
    supportsTools: false,
    inputCostPer1k: 0.015,
    outputCostPer1k: 0.06,
  },
  'o1-mini': {
    name: 'o1 Mini',
    contextWindow: 128000,
    maxOutput: 65536,
    supportsTools: false,
    inputCostPer1k: 0.003,
    outputCostPer1k: 0.012,
  },
  // Legacy models
  'gpt-4-turbo': {
    name: 'GPT-4 Turbo',
    contextWindow: 128000,
    maxOutput: 4096,
    supportsTools: true,
    inputCostPer1k: 0.01,
    outputCostPer1k: 0.03,
  },
} as const;

export type OpenAIModelId = keyof typeof OPENAI_MODELS;

// =============================================================================
// Provider Class
// =============================================================================

export class OpenAIProvider {
  readonly id = 'openai';
  private config: OpenAIConfig;
  private baseURL: string;

  constructor(config: OpenAIConfig) {
    this.config = config;
    this.baseURL = config.baseURL || 'https://api.openai.com/v1';

    logger.info('OpenAI provider initialized', { model: config.model });
  }

  /**
   * Get the model ID
   */
  get model(): string {
    return this.config.model;
  }

  /**
   * Non-streaming completion
   */
  async complete(
    context: Context,
    options: OpenAIStreamOptions = {}
  ): Promise<AssistantMessage> {
    let result: AssistantMessage | null = null;

    for await (const event of this.stream(context, options)) {
      if (event.type === 'done') {
        result = event.message;
      }
    }

    if (!result) {
      throw new Error('No response received from OpenAI');
    }

    return result;
  }

  /**
   * Stream a response from OpenAI
   */
  async *stream(
    context: Context,
    options: OpenAIStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
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
      // Convert messages to OpenAI format
      const messages = this.convertMessages(context);
      const tools = context.tools ? this.convertTools(context.tools) : undefined;

      // Build request body
      const body: Record<string, unknown> = {
        model,
        messages,
        max_tokens: maxTokens,
        stream: true,
        stream_options: { include_usage: true },
      };

      if (options.temperature !== undefined) {
        body.temperature = options.temperature;
      }

      if (options.topP !== undefined) {
        body.top_p = options.topP;
      }

      if (options.frequencyPenalty !== undefined) {
        body.frequency_penalty = options.frequencyPenalty;
      }

      if (options.presencePenalty !== undefined) {
        body.presence_penalty = options.presencePenalty;
      }

      if (options.stopSequences?.length) {
        body.stop = options.stopSequences;
      }

      if (tools && tools.length > 0) {
        body.tools = tools;
        body.tool_choice = 'auto';
      }

      // Make streaming request
      const response = await fetch(`${this.baseURL}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.config.apiKey}`,
          ...(this.config.organization && {
            'OpenAI-Organization': this.config.organization,
          }),
        },
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        const error = await response.text();
        throw new Error(`OpenAI API error: ${response.status} - ${error}`);
      }

      // Process SSE stream
      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';
      let accumulatedText = '';
      const toolCalls: Map<number, { id: string; name: string; args: string }> = new Map();
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;
      const toolCallsStarted = new Set<number>();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // Process complete lines
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue;

          const data = line.slice(6);
          if (data === '[DONE]') continue;

          try {
            const chunk = JSON.parse(data) as OpenAIStreamChunk;

            // Process usage
            if (chunk.usage) {
              inputTokens = chunk.usage.prompt_tokens;
              outputTokens = chunk.usage.completion_tokens;
            }

            const choice = chunk.choices[0];
            if (!choice) continue;

            const delta = choice.delta;

            // Handle text content
            if (delta.content) {
              if (!textStarted) {
                textStarted = true;
                yield { type: 'text_start' };
              }
              accumulatedText += delta.content;
              yield { type: 'text_delta', delta: delta.content };
            }

            // Handle tool calls
            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                if (!toolCalls.has(tc.index)) {
                  toolCalls.set(tc.index, {
                    id: tc.id || '',
                    name: tc.function?.name || '',
                    args: '',
                  });
                }

                const existing = toolCalls.get(tc.index)!;

                if (tc.id) existing.id = tc.id;
                if (tc.function?.name) existing.name = tc.function.name;
                if (tc.function?.arguments) existing.args += tc.function.arguments;

                // Emit toolcall_start when we first get the name
                if (existing.id && existing.name && !toolCallsStarted.has(tc.index)) {
                  toolCallsStarted.add(tc.index);
                  yield {
                    type: 'toolcall_start',
                    toolCallId: existing.id,
                    name: existing.name,
                  };
                }

                // Emit delta for arguments
                if (tc.function?.arguments) {
                  yield {
                    type: 'toolcall_delta',
                    toolCallId: existing.id,
                    argumentsDelta: tc.function.arguments,
                  };
                }
              }
            }

            // Handle finish
            if (choice.finish_reason) {
              // Emit text_end if we had text
              if (textStarted) {
                yield { type: 'text_end', text: accumulatedText };
              }

              // Emit toolcall_end for each tool call
              for (const [, tc] of toolCalls) {
                if (tc.id && tc.name) {
                  let parsedArgs: Record<string, unknown> = {};
                  try {
                    parsedArgs = JSON.parse(tc.args || '{}');
                  } catch {
                    logger.warn('Failed to parse tool call arguments', { args: tc.args });
                  }
                  const toolCall: ToolCall = {
                    type: 'tool_use',
                    id: tc.id,
                    name: tc.name,
                    arguments: parsedArgs,
                  };
                  yield { type: 'toolcall_end', toolCall };
                }
              }

              // Build final message
              const content: (TextContent | ToolCall)[] = [];
              if (accumulatedText) {
                content.push({ type: 'text', text: accumulatedText });
              }
              for (const [, tc] of toolCalls) {
                if (tc.id && tc.name) {
                  let parsedArgs: Record<string, unknown> = {};
                  try {
                    parsedArgs = JSON.parse(tc.args || '{}');
                  } catch {
                    // Already logged above
                  }
                  content.push({
                    type: 'tool_use',
                    id: tc.id,
                    name: tc.name,
                    arguments: parsedArgs,
                  });
                }
              }

              const message: AssistantMessage = {
                role: 'assistant',
                content,
                usage: { inputTokens, outputTokens },
                stopReason: this.mapStopReason(choice.finish_reason),
              };

              yield {
                type: 'done',
                message,
                stopReason: choice.finish_reason,
              };
            }
          } catch (e) {
            logger.warn('Failed to parse chunk', { data, error: e });
          }
        }
      }
    } catch (error) {
      logger.error('Stream error', error instanceof Error ? error : new Error(String(error)));
      yield { type: 'error', error: error instanceof Error ? error : new Error(String(error)) };
    }
  }

  /**
   * Convert Tron messages to OpenAI format
   */
  private convertMessages(context: Context): OpenAIMessage[] {
    const messages: OpenAIMessage[] = [];

    // Add system prompt
    if (context.systemPrompt) {
      messages.push({
        role: 'system',
        content: context.systemPrompt,
      });
    }

    // Convert messages
    for (const msg of context.messages) {
      if (msg.role === 'user') {
        const content = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        messages.push({
          role: 'user',
          content,
        });
      } else if (msg.role === 'assistant') {
        const textParts = msg.content
          .filter(c => c.type === 'text')
          .map(c => (c as TextContent).text);

        const toolCalls = msg.content
          .filter((c): c is ToolCall => c.type === 'tool_use')
          .map(tc => ({
            id: tc.id,
            type: 'function' as const,
            function: {
              name: tc.name,
              arguments: JSON.stringify(tc.arguments),
            },
          }));

        messages.push({
          role: 'assistant',
          content: textParts.join('\n') || null,
          ...(toolCalls.length > 0 && { tool_calls: toolCalls }),
        });
      } else if (msg.role === 'toolResult') {
        const content = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        messages.push({
          role: 'tool',
          tool_call_id: msg.toolCallId,
          content,
        });
      }
    }

    return messages;
  }

  /**
   * Convert Tron tools to OpenAI format
   */
  private convertTools(tools: NonNullable<Context['tools']>): OpenAITool[] {
    return tools.map(tool => ({
      type: 'function' as const,
      function: {
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters as Record<string, unknown>,
      },
    }));
  }

  /**
   * Map OpenAI stop reason to our format
   */
  private mapStopReason(reason: string | null): AssistantMessage['stopReason'] {
    switch (reason) {
      case 'stop':
        return 'end_turn';
      case 'length':
        return 'max_tokens';
      case 'tool_calls':
        return 'tool_use';
      case 'content_filter':
        return 'end_turn';
      default:
        return 'end_turn';
    }
  }
}
