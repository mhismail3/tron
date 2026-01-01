/**
 * @fileoverview Google Gemini Provider
 *
 * Provides streaming support for Google Gemini models with:
 * - API key authentication
 * - Function/tool calling
 * - Streaming responses
 * - Compatible interface with other providers
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('google');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for Google provider
 */
export interface GoogleConfig {
  model: string;
  apiKey: string;
  maxTokens?: number;
  temperature?: number;
  baseURL?: string;
}

/**
 * Options for streaming requests
 */
export interface GoogleStreamOptions {
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  topK?: number;
  stopSequences?: string[];
}

/**
 * Gemini API content format
 */
interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

type GeminiPart =
  | { text: string }
  | { functionCall: { name: string; args: Record<string, unknown> } }
  | { functionResponse: { name: string; response: Record<string, unknown> } };

interface GeminiTool {
  functionDeclarations: Array<{
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  }>;
}

interface GeminiStreamChunk {
  candidates?: Array<{
    content?: {
      parts?: GeminiPart[];
      role?: string;
    };
    finishReason?: string;
  }>;
  usageMetadata?: {
    promptTokenCount: number;
    candidatesTokenCount: number;
    totalTokenCount: number;
  };
  error?: {
    code: number;
    message: string;
  };
}

// =============================================================================
// Model Constants
// =============================================================================

export const GEMINI_MODELS = {
  'gemini-2.0-flash-exp': {
    name: 'Gemini 2.0 Flash (Experimental)',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    inputCostPer1k: 0.0,
    outputCostPer1k: 0.0,
  },
  'gemini-1.5-pro': {
    name: 'Gemini 1.5 Pro',
    contextWindow: 2097152,
    maxOutput: 8192,
    supportsTools: true,
    inputCostPer1k: 0.00125,
    outputCostPer1k: 0.005,
  },
  'gemini-1.5-flash': {
    name: 'Gemini 1.5 Flash',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    inputCostPer1k: 0.000075,
    outputCostPer1k: 0.0003,
  },
  'gemini-1.5-flash-8b': {
    name: 'Gemini 1.5 Flash 8B',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    inputCostPer1k: 0.0000375,
    outputCostPer1k: 0.00015,
  },
} as const;

export type GeminiModelId = keyof typeof GEMINI_MODELS;

// =============================================================================
// Provider Class
// =============================================================================

export class GoogleProvider {
  readonly id = 'google';
  private config: GoogleConfig;
  private baseURL: string;

  constructor(config: GoogleConfig) {
    this.config = config;
    this.baseURL = config.baseURL || 'https://generativelanguage.googleapis.com/v1beta';

    logger.info('Google provider initialized', { model: config.model });
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
    options: GoogleStreamOptions = {}
  ): Promise<AssistantMessage> {
    let result: AssistantMessage | null = null;

    for await (const event of this.stream(context, options)) {
      if (event.type === 'done') {
        result = event.message;
      }
    }

    if (!result) {
      throw new Error('No response received from Google');
    }

    return result;
  }

  /**
   * Stream a response from Gemini
   */
  async *stream(
    context: Context,
    options: GoogleStreamOptions = {}
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
      // Convert messages to Gemini format
      const contents = this.convertMessages(context);
      const tools = context.tools ? this.convertTools(context.tools) : undefined;

      // Build request body
      const body: Record<string, unknown> = {
        contents,
        generationConfig: {
          maxOutputTokens: maxTokens,
          ...(options.temperature !== undefined && { temperature: options.temperature }),
          ...(options.topP !== undefined && { topP: options.topP }),
          ...(options.topK !== undefined && { topK: options.topK }),
          ...(options.stopSequences?.length && { stopSequences: options.stopSequences }),
        },
      };

      // Add system instruction if provided
      if (context.systemPrompt) {
        body.systemInstruction = {
          parts: [{ text: context.systemPrompt }],
        };
      }

      if (tools && tools.length > 0) {
        body.tools = tools;
      }

      // Make streaming request
      const url = `${this.baseURL}/models/${model}:streamGenerateContent?key=${this.config.apiKey}&alt=sse`;

      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        const error = await response.text();
        throw new Error(`Gemini API error: ${response.status} - ${error}`);
      }

      // Process SSE stream
      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';
      let accumulatedText = '';
      const toolCalls: Array<{ id: string; name: string; args: Record<string, unknown> }> = [];
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;
      let toolCallIndex = 0;

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
          if (!data.trim()) continue;

          try {
            const chunk = JSON.parse(data) as GeminiStreamChunk;

            // Check for errors
            if (chunk.error) {
              throw new Error(`Gemini error: ${chunk.error.message}`);
            }

            // Process usage
            if (chunk.usageMetadata) {
              inputTokens = chunk.usageMetadata.promptTokenCount;
              outputTokens = chunk.usageMetadata.candidatesTokenCount;
            }

            const candidate = chunk.candidates?.[0];
            if (!candidate?.content?.parts) continue;

            for (const part of candidate.content.parts) {
              // Handle text content
              if ('text' in part) {
                if (!textStarted) {
                  textStarted = true;
                  yield { type: 'text_start' };
                }
                accumulatedText += part.text;
                yield { type: 'text_delta', delta: part.text };
              }

              // Handle function calls
              if ('functionCall' in part) {
                const fc = part.functionCall;
                const id = `call_${toolCallIndex++}`;

                yield {
                  type: 'toolcall_start',
                  toolCallId: id,
                  name: fc.name,
                };

                yield {
                  type: 'toolcall_delta',
                  toolCallId: id,
                  argumentsDelta: JSON.stringify(fc.args),
                };

                toolCalls.push({
                  id,
                  name: fc.name,
                  args: fc.args,
                });

                const toolCall: ToolCall = {
                  type: 'tool_use',
                  id,
                  name: fc.name,
                  arguments: fc.args,
                };
                yield { type: 'toolcall_end', toolCall };
              }
            }

            // Handle finish
            if (candidate.finishReason) {
              // Emit text_end if we had text
              if (textStarted) {
                yield { type: 'text_end', text: accumulatedText };
              }

              // Build final message
              const content: (TextContent | ToolCall)[] = [];
              if (accumulatedText) {
                content.push({ type: 'text', text: accumulatedText });
              }
              for (const tc of toolCalls) {
                content.push({
                  type: 'tool_use',
                  id: tc.id,
                  name: tc.name,
                  arguments: tc.args,
                });
              }

              const message: AssistantMessage = {
                role: 'assistant',
                content,
                usage: { inputTokens, outputTokens },
                stopReason: this.mapStopReason(candidate.finishReason),
              };

              yield {
                type: 'done',
                message,
                stopReason: candidate.finishReason,
              };
            }
          } catch (e) {
            if (e instanceof Error && e.message.startsWith('Gemini')) {
              throw e;
            }
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
   * Convert Tron messages to Gemini format
   */
  private convertMessages(context: Context): GeminiContent[] {
    const contents: GeminiContent[] = [];

    for (const msg of context.messages) {
      if (msg.role === 'user') {
        const parts: GeminiPart[] = [];

        if (typeof msg.content === 'string') {
          parts.push({ text: msg.content });
        } else {
          for (const c of msg.content) {
            if (c.type === 'text') {
              parts.push({ text: c.text });
            }
            // Note: Image handling would go here for multimodal
          }
        }

        contents.push({ role: 'user', parts });
      } else if (msg.role === 'assistant') {
        const parts: GeminiPart[] = [];

        for (const c of msg.content) {
          if (c.type === 'text') {
            parts.push({ text: c.text });
          } else if (c.type === 'tool_use') {
            parts.push({
              functionCall: {
                name: c.name,
                args: c.arguments,
              },
            });
          }
        }

        contents.push({ role: 'model', parts });
      } else if (msg.role === 'toolResult') {
        const content = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        // Gemini expects function responses as model turns followed by user turns
        // This is a simplification - actual implementation may need adjustment
        contents.push({
          role: 'user',
          parts: [{
            functionResponse: {
              name: 'tool_result',
              response: {
                result: content,
                tool_call_id: msg.toolCallId,
              },
            },
          }],
        });
      }
    }

    return contents;
  }

  /**
   * Convert Tron tools to Gemini format
   */
  private convertTools(tools: NonNullable<Context['tools']>): GeminiTool[] {
    return [{
      functionDeclarations: tools.map(tool => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters as Record<string, unknown>,
      })),
    }];
  }

  /**
   * Map Gemini stop reason to our format
   */
  private mapStopReason(reason: string): AssistantMessage['stopReason'] {
    switch (reason) {
      case 'STOP':
        return 'end_turn';
      case 'MAX_TOKENS':
        return 'max_tokens';
      case 'SAFETY':
        return 'end_turn';
      case 'RECITATION':
        return 'end_turn';
      case 'OTHER':
        return 'end_turn';
      default:
        return 'end_turn';
    }
  }
}
