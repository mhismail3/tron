/**
 * @fileoverview OpenAI Codex Provider
 *
 * Provides streaming support for OpenAI Codex models with:
 * - OAuth authentication (ChatGPT Plus/Pro subscription)
 * - Reasoning effort parameter support (low/medium/high/xhigh)
 * - Tool/function calling
 * - Streaming responses via Responses API
 *
 * Based on: https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/providers/openai-codex-responses.ts
 */

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import type {
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('openai-codex');

// =============================================================================
// Types
// =============================================================================

/**
 * Reasoning effort levels for Codex models
 */
export type ReasoningEffort = 'low' | 'medium' | 'high' | 'xhigh';

/**
 * OAuth authentication for Codex
 */
export interface CodexOAuth {
  type: 'oauth';
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

/**
 * Configuration for OpenAI Codex provider
 */
export interface OpenAICodexConfig {
  model: string;
  auth: CodexOAuth;
  maxTokens?: number;
  temperature?: number;
  baseURL?: string;
  reasoningEffort?: ReasoningEffort;
}

/**
 * Options for streaming requests
 */
export interface OpenAICodexStreamOptions {
  maxTokens?: number;
  temperature?: number;
  reasoningEffort?: ReasoningEffort;
  stopSequences?: string[];
}

// =============================================================================
// Responses API Types (from pi-mono)
// =============================================================================

/**
 * Input item for Responses API
 */
type ResponsesInputItem =
  | { type: 'input_text'; text: string }
  | { type: 'message'; role: 'user' | 'assistant'; content: MessageContent[]; id?: string }
  | { type: 'function_call'; id?: string; call_id: string; name: string; arguments: string }
  | { type: 'function_call_output'; call_id: string; output: string };

type MessageContent =
  | { type: 'output_text'; text: string }
  | { type: 'input_text'; text: string };

/**
 * Tool definition for Responses API
 */
interface ResponsesTool {
  type: 'function';
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}


/**
 * SSE event types from Responses API
 */
interface ResponsesStreamEvent {
  type: string;
  // For response.output_text.delta
  delta?: string;
  // For response.output_item.added
  item?: {
    type: string;
    id?: string;
    call_id?: string;
    name?: string;
    arguments?: string;
    content?: Array<{ type: string; text?: string }>;
  };
  // For response.function_call_arguments.delta
  call_id?: string;
  // For response.completed
  response?: {
    id: string;
    output: Array<{
      type: string;
      id?: string;
      call_id?: string;
      name?: string;
      arguments?: string;
      content?: Array<{ type: string; text?: string }>;
    }>;
    usage?: {
      input_tokens: number;
      output_tokens: number;
    };
  };
}

// =============================================================================
// Model Constants
// =============================================================================

export const OPENAI_CODEX_MODELS = {
  'gpt-5.2-codex': {
    name: 'OpenAI GPT-5.2 Codex',
    shortName: 'GPT-5.2 Codex',
    family: 'GPT-5.2',
    tier: 'flagship',
    contextWindow: 192000,
    maxOutput: 16384,
    supportsTools: true,
    supportsReasoning: true,
    reasoningLevels: ['low', 'medium', 'high', 'xhigh'] as ReasoningEffort[],
    defaultReasoningLevel: 'medium' as ReasoningEffort,
    inputCostPerMillion: 0,
    outputCostPerMillion: 0,
    description: 'Latest GPT-5.2 Codex - most advanced coding model',
  },
  'gpt-5.1-codex-max': {
    name: 'OpenAI GPT-5.1 Codex Max',
    shortName: 'GPT-5.1 Codex Max',
    family: 'GPT-5.1',
    tier: 'flagship',
    contextWindow: 192000,
    maxOutput: 16384,
    supportsTools: true,
    supportsReasoning: true,
    reasoningLevels: ['low', 'medium', 'high', 'xhigh'] as ReasoningEffort[],
    defaultReasoningLevel: 'high' as ReasoningEffort,
    inputCostPerMillion: 0,
    outputCostPerMillion: 0,
    description: 'GPT-5.1 Codex Max - deep reasoning capabilities',
  },
  'gpt-5.1-codex-mini': {
    name: 'OpenAI GPT-5.1 Codex Mini',
    shortName: 'GPT-5.1 Codex Mini',
    family: 'GPT-5.1',
    tier: 'standard',
    contextWindow: 192000,
    maxOutput: 16384,
    supportsTools: true,
    supportsReasoning: true,
    reasoningLevels: ['low', 'medium', 'high'] as ReasoningEffort[],
    defaultReasoningLevel: 'low' as ReasoningEffort,
    inputCostPerMillion: 0,
    outputCostPerMillion: 0,
    description: 'GPT-5.1 Codex Mini - faster and more efficient',
  },
} as const;

export type OpenAICodexModelId = keyof typeof OPENAI_CODEX_MODELS;

// =============================================================================
// Default Instructions (required for ChatGPT backend API)
// =============================================================================

/**
 * Load Codex system instructions from markdown file.
 * The ChatGPT backend API requires an instructions field - it cannot be omitted.
 * ChatGPT OAuth only accepts authorized system prompts, so we use a Codex-compatible prompt.
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const CODEX_INSTRUCTIONS_PATH = join(__dirname, 'prompts', 'codex-instructions.md');
const CODEX_DEFAULT_INSTRUCTIONS = readFileSync(CODEX_INSTRUCTIONS_PATH, 'utf-8');

// =============================================================================
// Settings Helper
// =============================================================================

function getCodexSettings() {
  const settings = getSettings();
  return settings.api.openaiCodex;
}

// =============================================================================
// Provider Class
// =============================================================================

export class OpenAICodexProvider {
  readonly id = 'openai-codex';
  private config: OpenAICodexConfig;
  private baseURL: string;

  constructor(config: OpenAICodexConfig) {
    this.config = config;
    const codexSettings = getCodexSettings();
    this.baseURL = config.baseURL || codexSettings?.baseUrl || 'https://chatgpt.com/backend-api';

    logger.info('OpenAI Codex provider initialized', { model: config.model });
  }

  /**
   * Get the model ID
   */
  get model(): string {
    return this.config.model;
  }

  /**
   * Extract account ID from JWT token
   */
  private extractAccountId(token: string): string {
    try {
      const parts = token.split('.');
      if (parts.length < 2 || !parts[1]) {
        return '';
      }
      const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString()) as Record<string, unknown>;
      const authClaims = (payload['https://api.openai.com/auth'] ?? {}) as Record<string, unknown>;
      return (authClaims.chatgpt_account_id ?? '') as string;
    } catch (error) {
      logger.warn('Failed to extract account ID from JWT', { error });
      return '';
    }
  }

  /**
   * Check if tokens need refresh
   */
  private shouldRefreshTokens(): boolean {
    const codexSettings = getCodexSettings();
    const bufferSeconds = codexSettings?.tokenExpiryBufferSeconds ?? 300;
    // expiresAt is in milliseconds from our auth flow
    return Date.now() > this.config.auth.expiresAt - (bufferSeconds * 1000);
  }

  /**
   * Refresh OAuth tokens
   */
  private async refreshTokens(): Promise<{ accessToken: string; expiresAt: number }> {
    const codexSettings = getCodexSettings();
    const tokenUrl = codexSettings?.tokenUrl ?? 'https://auth.openai.com/oauth/token';
    const clientId = codexSettings?.clientId ?? 'app_EMoamEEZ73f0CkXaXp7hrann';

    logger.info('Refreshing Codex OAuth tokens');

    const response = await fetch(tokenUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        grant_type: 'refresh_token',
        refresh_token: this.config.auth.refreshToken,
        client_id: clientId,
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Token refresh failed: ${response.status} - ${error}`);
    }

    const data = await response.json() as { access_token: string; expires_in: number };
    return {
      accessToken: data.access_token,
      expiresAt: Date.now() + data.expires_in * 1000,
    };
  }

  /**
   * Ensure tokens are valid, refresh if needed
   */
  private async ensureValidTokens(): Promise<void> {
    if (this.shouldRefreshTokens()) {
      const newTokens = await this.refreshTokens();
      this.config.auth.accessToken = newTokens.accessToken;
      this.config.auth.expiresAt = newTokens.expiresAt;
    }
  }

  /**
   * Non-streaming completion
   */
  async complete(
    context: Context,
    options: OpenAICodexStreamOptions = {}
  ): Promise<AssistantMessage> {
    let result: AssistantMessage | null = null;

    for await (const event of this.stream(context, options)) {
      if (event.type === 'done') {
        result = event.message;
      }
    }

    if (!result) {
      throw new Error('No response received from OpenAI Codex');
    }

    return result;
  }

  /**
   * Stream a response from OpenAI Codex using Responses API
   */
  async *stream(
    context: Context,
    options: OpenAICodexStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    await this.ensureValidTokens();

    const model = this.config.model;
    const maxTokens = options.maxTokens ?? this.config.maxTokens ?? 16384;
    const reasoningEffort = options.reasoningEffort
      ?? this.config.reasoningEffort
      ?? getCodexSettings()?.defaultReasoningEffort
      ?? 'medium';

    logger.debug('Starting Codex stream', {
      model,
      maxTokens,
      reasoningEffort,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
    });

    yield { type: 'start' };

    try {
      const accountId = this.extractAccountId(this.config.auth.accessToken);

      // Build headers
      const headers: Record<string, string> = {
        'Authorization': `Bearer ${this.config.auth.accessToken}`,
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'openai-beta': 'responses=experimental',
        'openai-originator': 'codex_cli_rs',
      };

      if (accountId) {
        headers['chatgpt-account-id'] = accountId;
      }

      // Convert to Responses API format
      const input = this.convertToResponsesInput(context);
      const tools = context.tools ? this.convertTools(context.tools) : undefined;

      // Build request body (Responses API format)
      // The instructions field is REQUIRED by the ChatGPT backend API.
      // ChatGPT OAuth only accepts authorized system prompts - custom instructions will fail validation.
      // Note: max_output_tokens is NOT supported by the ChatGPT backend API.
      const body: Record<string, unknown> = {
        model,
        input,
        instructions: CODEX_DEFAULT_INSTRUCTIONS,
        stream: true,
        store: false,
      };

      if (reasoningEffort) {
        body.reasoning = { effort: reasoningEffort };
      }

      if (options.temperature !== undefined) {
        body.temperature = options.temperature;
      }

      if (tools && tools.length > 0) {
        body.tools = tools;
      }

      logger.debug('Codex request body', {
        model,
        inputCount: input.length,
        toolCount: tools?.length ?? 0,
      });

      // POST to Codex responses endpoint
      const response = await fetch(`${this.baseURL}/codex/responses`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        const error = await response.text();
        throw new Error(`OpenAI Codex API error: ${response.status} - ${error}`);
      }

      // Process SSE stream
      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const decoder = new TextDecoder();
      let buffer = '';
      let accumulatedText = '';
      const toolCalls: Map<string, { id: string; name: string; args: string }> = new Map();
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // Process complete lines
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue;

          const data = line.slice(6).trim();
          if (!data || data === '[DONE]') continue;

          try {
            const event = JSON.parse(data) as ResponsesStreamEvent;

            // Handle different event types
            switch (event.type) {
              case 'response.output_text.delta':
                if (event.delta) {
                  if (!textStarted) {
                    textStarted = true;
                    yield { type: 'text_start' };
                  }
                  accumulatedText += event.delta;
                  yield { type: 'text_delta', delta: event.delta };
                }
                break;

              case 'response.output_item.added':
                if (event.item?.type === 'function_call' && event.item.call_id && event.item.name) {
                  const callId = event.item.call_id;
                  toolCalls.set(callId, {
                    id: callId,
                    name: event.item.name,
                    args: event.item.arguments || '',
                  });
                  yield {
                    type: 'toolcall_start',
                    toolCallId: callId,
                    name: event.item.name,
                  };
                }
                break;

              case 'response.function_call_arguments.delta':
                if (event.call_id && event.delta) {
                  const tc = toolCalls.get(event.call_id);
                  if (tc) {
                    tc.args += event.delta;
                    yield {
                      type: 'toolcall_delta',
                      toolCallId: event.call_id,
                      argumentsDelta: event.delta,
                    };
                  }
                }
                break;

              case 'response.completed':
                if (event.response) {
                  // Get usage
                  if (event.response.usage) {
                    inputTokens = event.response.usage.input_tokens;
                    outputTokens = event.response.usage.output_tokens;
                  }

                  // Process output items
                  for (const item of event.response.output) {
                    if (item.type === 'message' && item.content) {
                      for (const content of item.content) {
                        if (content.type === 'output_text' && content.text) {
                          if (!textStarted) {
                            textStarted = true;
                            accumulatedText = content.text;
                          }
                        }
                      }
                    } else if (item.type === 'function_call' && item.call_id) {
                      if (!toolCalls.has(item.call_id)) {
                        toolCalls.set(item.call_id, {
                          id: item.call_id,
                          name: item.name || '',
                          args: item.arguments || '',
                        });
                      }
                    }
                  }

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
                    stopReason: toolCalls.size > 0 ? 'tool_use' : 'end_turn',
                  };

                  yield {
                    type: 'done',
                    message,
                    stopReason: toolCalls.size > 0 ? 'tool_calls' : 'stop',
                  };
                }
                break;
            }
          } catch (e) {
            logger.warn('Failed to parse Codex event', { data, error: e });
          }
        }
      }
    } catch (error) {
      logger.error('Codex stream error', error instanceof Error ? error : new Error(String(error)));
      yield { type: 'error', error: error instanceof Error ? error : new Error(String(error)) };
    }
  }

  /**
   * Convert Tron context to Responses API input format
   */
  private convertToResponsesInput(context: Context): ResponsesInputItem[] {
    const input: ResponsesInputItem[] = [];

    for (const msg of context.messages) {
      if (msg.role === 'user') {
        const text = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        // ChatGPT backend API requires 'message' type, not 'input_text'
        input.push({
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text }],
        });
      } else if (msg.role === 'assistant') {
        // Handle assistant messages with text
        const textParts = msg.content
          .filter(c => c.type === 'text')
          .map(c => (c as TextContent).text);

        if (textParts.length > 0) {
          input.push({
            type: 'message',
            role: 'assistant',
            content: textParts.map(text => ({ type: 'output_text', text })),
          });
        }

        // Handle tool calls from assistant
        const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
        for (const tc of toolUses) {
          input.push({
            type: 'function_call',
            call_id: tc.id,
            name: tc.name,
            // Ensure arguments is always a valid JSON string (required by Responses API)
            arguments: JSON.stringify(tc.arguments ?? {}),
          });
        }
      } else if (msg.role === 'toolResult') {
        const output = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        // Truncate long outputs (Codex has 16k limit per output)
        const truncatedOutput = output.length > 16000
          ? output.slice(0, 16000) + '\n... [truncated]'
          : output;

        input.push({
          type: 'function_call_output',
          call_id: msg.toolCallId,
          output: truncatedOutput,
        });
      }
    }

    return input;
  }

  /**
   * Convert Tron tools to Responses API format
   */
  private convertTools(tools: NonNullable<Context['tools']>): ResponsesTool[] {
    return tools.map(tool => ({
      type: 'function' as const,
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters as Record<string, unknown>,
    }));
  }
}
