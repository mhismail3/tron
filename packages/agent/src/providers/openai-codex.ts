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
  ThinkingContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/index.js';
import { getSettings } from '../settings/index.js';
import { saveProviderOAuthTokens, type OAuthTokens } from '../auth/index.js';
import { withProviderRetry, type StreamRetryConfig } from './base/index.js';

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
  /** Retry configuration for transient failures (default: enabled with 3 retries) */
  retry?: StreamRetryConfig | false;
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
  // For response.output_text.delta and response.reasoning_summary_text.delta
  delta?: string;
  // For reasoning_summary_text.delta and reasoning_text.delta
  summary_index?: number;
  content_index?: number;
  // For response.output_item.added
  item?: {
    type: string;  // 'function_call' | 'message' | 'reasoning'
    id?: string;
    call_id?: string;
    name?: string;
    arguments?: string;
    content?: Array<{ type: string; text?: string }>;
    summary?: Array<{ type: string; text?: string }>;  // For reasoning items
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
      summary?: Array<{ type: string; text?: string }>;  // For reasoning items
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
    supportsThinking: true,
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
    supportsThinking: true,
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
    supportsThinking: true,
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
 * ChatGPT OAuth validates instructions EXACTLY - we cannot modify them at all.
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const CODEX_INSTRUCTIONS_PATH = join(__dirname, 'prompts', 'codex-instructions.md');
const CODEX_DEFAULT_INSTRUCTIONS = readFileSync(CODEX_INSTRUCTIONS_PATH, 'utf-8');

/**
 * Generate a tool clarification message to prepend to conversation.
 * Since we can't modify the system prompt, we add this as a "developer" context message.
 *
 * This includes:
 * 1. Tron identity and role
 * 2. Available tools and their descriptions
 * 3. Bash capabilities (since Codex's default instructions mention shell which we don't use)
 */
function generateToolClarificationMessage(
  tools: Array<{ name: string; description: string; parameters?: unknown }>,
  workingDirectory?: string
): string {
  const toolDescriptions = tools.map(t => {
    const params = t.parameters as { properties?: Record<string, { description?: string }>; required?: string[] } | undefined;
    const requiredParams = params?.required?.join(', ') || 'none';
    return `- **${t.name}**: ${t.description} (required params: ${requiredParams})`;
  }).join('\n');

  const cwdLine = workingDirectory ? `\nCurrent working directory: ${workingDirectory}` : '';

  return `[TRON CONTEXT]
You are Tron, an AI coding assistant with full access to the user's file system.
${cwdLine}

## Available Tools
The tools mentioned in the system instructions (shell, apply_patch, etc.) are NOT available. Use ONLY these tools:

${toolDescriptions}

## Bash Tool Capabilities
The Bash tool runs commands on the user's local machine with FULL capabilities:
- **Network access**: Use curl, wget, or other tools to fetch URLs, APIs, websites
- **File system**: Full read/write access to files and directories
- **Git operations**: Clone, commit, push, pull, etc.
- **Package managers**: npm, pip, brew, apt, etc.
- **Any installed CLI tools**: rg, jq, python, node, etc.

When asked to visit a website or fetch data from the internet, USE the Bash tool with curl. Example: \`curl -s https://example.com\`

## Important Rules
1. You MUST provide ALL required parameters when calling tools - never call with empty arguments
2. For file paths, provide the complete path (e.g., "src/index.ts" or "/absolute/path/file.txt")
3. Confidently interpret and explain results from tool calls - you have full context of what was returned
4. Be helpful, accurate, and efficient when working with code
5. Read existing files to understand context before making changes
6. Make targeted, minimal edits rather than rewriting entire files`;
}

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
  private retryConfig: StreamRetryConfig | false;

  constructor(config: OpenAICodexConfig) {
    this.config = config;
    const codexSettings = getCodexSettings();
    this.baseURL = config.baseURL || codexSettings?.baseUrl || 'https://chatgpt.com/backend-api';
    // Default to enabled retry with standard config
    this.retryConfig = config.retry === false ? false : (config.retry ?? {});

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
  private async refreshTokens(): Promise<OAuthTokens> {
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

    const data = await response.json() as {
      access_token: string;
      refresh_token: string;
      expires_in: number;
    };

    const newTokens: OAuthTokens = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: Date.now() + data.expires_in * 1000,
    };

    // Persist refreshed tokens to disk
    await saveProviderOAuthTokens('openai-codex', newTokens);
    logger.info('Persisted refreshed Codex OAuth tokens');

    return newTokens;
  }

  /**
   * Ensure tokens are valid, refresh if needed
   */
  private async ensureValidTokens(): Promise<void> {
    if (this.shouldRefreshTokens()) {
      const newTokens = await this.refreshTokens();
      this.config.auth.accessToken = newTokens.accessToken;
      this.config.auth.refreshToken = newTokens.refreshToken;
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
   * Stream a response from OpenAI Codex with automatic retry on transient failures
   */
  async *stream(
    context: Context,
    options: OpenAICodexStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    // Ensure tokens are valid before starting (and before each retry)
    await this.ensureValidTokens();

    // If retry is disabled, stream directly
    if (this.retryConfig === false) {
      yield* this.streamInternal(context, options);
      return;
    }

    // Wrap with retry for transient failures
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
    options: OpenAICodexStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {

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

      // Prepend tool clarification message ONLY on first turn of session
      // (when there are no assistant messages yet in the history)
      const hasAssistantMessages = context.messages.some(m => m.role === 'assistant');
      if (context.tools && context.tools.length > 0 && !hasAssistantMessages) {
        const clarificationText = generateToolClarificationMessage(
          context.tools,
          context.workingDirectory
        );
        input.unshift({
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text: clarificationText }],
        });
        logger.debug('Prepended tool clarification message (first turn)', {
          workingDirectory: context.workingDirectory,
        });
      }

      // Build request body (Responses API format)
      // The instructions field is REQUIRED by the ChatGPT backend API.
      // ChatGPT OAuth validates instructions EXACTLY - we cannot modify them.
      // Note: max_output_tokens is NOT supported by the ChatGPT backend API.
      const body: Record<string, unknown> = {
        model,
        input,
        instructions: CODEX_DEFAULT_INSTRUCTIONS,
        stream: true,
        store: false,
      };

      if (reasoningEffort) {
        // gpt-5.2-codex only supports 'detailed' summary (not 'concise')
        body.reasoning = { effort: reasoningEffort, summary: 'detailed' };
      }

      if (options.temperature !== undefined) {
        body.temperature = options.temperature;
      }

      if (tools && tools.length > 0) {
        body.tools = tools;
      }

      logger.trace('Codex request body', {
        model,
        inputCount: input.length,
        toolCount: tools?.length ?? 0,
        reasoning: body.reasoning,
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
      let accumulatedThinking = '';
      const toolCalls: Map<string, { id: string; name: string; args: string }> = new Map();
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;
      let thinkingStarted = false;
      // Track seen thinking content to prevent duplication across different event types
      const seenThinkingTexts = new Set<string>();

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

            // Log SSE events at trace level for debugging reasoning/streaming issues
            const eventItem = (event as any).item;
            logger.trace('Codex SSE event received', {
              type: event.type,
              hasDelta: !!event.delta,
              deltaPreview: event.delta?.substring(0, 50),
              hasItem: !!eventItem,
              itemType: eventItem?.type,
              // Capture reasoning summary if present in item
              hasSummary: !!eventItem?.summary,
              summaryLength: eventItem?.summary?.length,
              summaryPreview: eventItem?.summary?.[0]?.text?.substring(0, 100),
            });

            // Log all events for debugging tool call issues
            if (event.type?.includes('function') || event.type?.includes('output_item')) {
              logger.debug('Codex SSE event', {
                type: event.type,
                hasItem: !!(event as any).item,
                itemType: (event as any).item?.type,
                callId: (event as any).call_id || (event as any).item?.call_id,
                hasArguments: !!(event as any).item?.arguments || !!(event as any).delta,
                argumentsPreview: ((event as any).item?.arguments || (event as any).delta || '').substring(0, 100),
              });
            }

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
                  const initialArgs = event.item.arguments || '';
                  logger.debug('Tool call added via output_item.added', {
                    callId,
                    name: event.item.name,
                    hasArguments: !!event.item.arguments,
                    argumentsLength: initialArgs.length,
                  });
                  toolCalls.set(callId, {
                    id: callId,
                    name: event.item.name,
                    args: initialArgs,
                  });
                  yield {
                    type: 'toolcall_start',
                    toolCallId: callId,
                    name: event.item.name,
                  };
                } else if (event.item?.type === 'reasoning') {
                  // Reasoning item added - start thinking if not already started
                  if (!thinkingStarted) {
                    thinkingStarted = true;
                    yield { type: 'thinking_start' };
                  }
                }
                break;

              case 'response.output_item.done':
                // Handle completed reasoning items - summary may be in item.summary
                // Only process if we didn't already get content via streaming deltas
                // (deltas come as chunks so Set-based dedup doesn't work when assembled text differs)
                if (event.item?.type === 'reasoning' && event.item.summary && !accumulatedThinking) {
                  if (!thinkingStarted) {
                    thinkingStarted = true;
                    yield { type: 'thinking_start' };
                  }
                  for (const summaryPart of event.item.summary) {
                    if (summaryPart.type === 'summary_text' && summaryPart.text) {
                      // Add to set so subsequent deltas with same text are skipped
                      seenThinkingTexts.add(summaryPart.text);
                      accumulatedThinking += summaryPart.text;
                      yield { type: 'thinking_delta', delta: summaryPart.text };
                    }
                  }
                }
                break;

              case 'response.reasoning_summary_part.added':
                // A new reasoning summary part is being added
                if (!thinkingStarted) {
                  thinkingStarted = true;
                  yield { type: 'thinking_start' };
                }
                break;

              case 'response.reasoning_summary_text.delta':
                // Delta for reasoning summary text - skip if we already have this content
                if (event.delta && !seenThinkingTexts.has(event.delta)) {
                  seenThinkingTexts.add(event.delta);
                  if (!thinkingStarted) {
                    thinkingStarted = true;
                    yield { type: 'thinking_start' };
                  }
                  accumulatedThinking += event.delta;
                  yield { type: 'thinking_delta', delta: event.delta };
                }
                break;

              case 'response.function_call_arguments.delta':
                if (event.call_id && event.delta) {
                  const tc = toolCalls.get(event.call_id);
                  if (tc) {
                    tc.args += event.delta;
                    logger.debug('Tool call arguments delta', {
                      callId: event.call_id,
                      deltaLength: event.delta.length,
                      totalArgsLength: tc.args.length,
                    });
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
                  // Log the full response for debugging - include reasoning items
                  const reasoningItems = event.response.output?.filter((o: any) => o.type === 'reasoning') ?? [];
                  logger.trace('Codex response.completed', {
                    outputCount: event.response.output?.length ?? 0,
                    outputTypes: event.response.output?.map((o: any) => o.type) ?? [],
                    reasoningItemCount: reasoningItems.length,
                    reasoningItems: reasoningItems.map((r: any) => ({
                      hasSummary: !!r.summary,
                      summaryLength: r.summary?.length,
                      summaryTexts: r.summary?.map((s: any) => s.text?.substring(0, 200)),
                    })),
                    functionCalls: event.response.output?.filter((o: any) => o.type === 'function_call').map((fc: any) => ({
                      name: fc.name,
                      callId: fc.call_id,
                      hasArguments: !!fc.arguments,
                      argumentsLength: fc.arguments?.length ?? 0,
                      argumentsPreview: fc.arguments?.substring(0, 200),
                    })) ?? [],
                  });

                  // Get usage
                  if (event.response.usage) {
                    inputTokens = event.response.usage.input_tokens;
                    outputTokens = event.response.usage.output_tokens;
                  }

                  // Process output items from completed response
                  // This is the authoritative source - update/add all tool calls from here
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
                    } else if (item.type === 'reasoning' && item.summary && !accumulatedThinking) {
                      // Handle reasoning item from completed response - only if we didn't get content via deltas
                      // (deltas come as chunks so Set-based dedup doesn't work here)
                      for (const summaryItem of item.summary) {
                        if (summaryItem.type === 'summary_text' && summaryItem.text) {
                          if (!thinkingStarted) {
                            thinkingStarted = true;
                            yield { type: 'thinking_start' };
                          }
                          accumulatedThinking = summaryItem.text;
                        }
                      }
                    } else if (item.type === 'function_call' && item.call_id) {
                      logger.debug('Tool call in completed response', {
                        callId: item.call_id,
                        name: item.name,
                        hasArguments: !!item.arguments,
                        argumentsLength: item.arguments?.length ?? 0,
                        argumentsPreview: item.arguments?.substring(0, 100),
                      });
                      const existing = toolCalls.get(item.call_id);
                      if (existing) {
                        // Update with completed response data if streaming didn't capture it
                        // Prefer completed response arguments if streaming didn't accumulate any
                        if (item.arguments && !existing.args) {
                          logger.debug('Updating tool call args from completed response', {
                            callId: item.call_id,
                            existingArgsLength: existing.args.length,
                            newArgsLength: item.arguments.length,
                          });
                          existing.args = item.arguments;
                        }
                        if (item.name && !existing.name) {
                          existing.name = item.name;
                        }
                      } else {
                        toolCalls.set(item.call_id, {
                          id: item.call_id,
                          name: item.name || '',
                          args: item.arguments || '',
                        });
                      }
                    }
                  }

                  // Emit thinking_end if we had thinking
                  if (thinkingStarted) {
                    yield { type: 'thinking_end', thinking: accumulatedThinking };
                  }

                  // Emit text_end if we had text
                  if (textStarted) {
                    yield { type: 'text_end', text: accumulatedText };
                  }

                  // Emit toolcall_end for each tool call
                  for (const [, tc] of toolCalls) {
                    if (tc.id && tc.name) {
                      logger.debug('Final tool call before emit', {
                        id: tc.id,
                        name: tc.name,
                        argsLength: tc.args.length,
                        argsPreview: tc.args.substring(0, 200),
                      });
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
                  const content: (TextContent | ThinkingContent | ToolCall)[] = [];
                  if (accumulatedThinking) {
                    content.push({ type: 'thinking', thinking: accumulatedThinking });
                  }
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
                    usage: { inputTokens, outputTokens, providerType: 'openai-codex' as const },
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
   *
   * Note: Tool call IDs from other providers (e.g., Anthropic's `toolu_` prefix)
   * are remapped to OpenAI-compatible format to support mid-session provider switching.
   */
  private convertToResponsesInput(context: Context): ResponsesInputItem[] {
    const input: ResponsesInputItem[] = [];

    // Build a mapping of original tool call IDs to normalized IDs.
    // This is necessary when switching providers mid-session, as tool call IDs
    // from other providers (e.g., Anthropic's `toolu_01...`) are not recognized.
    // Only remap IDs that don't already look like OpenAI format.
    const idMapping = new Map<string, string>();
    let idCounter = 0;

    // First pass: collect tool call IDs that need remapping (non-OpenAI format)
    for (const msg of context.messages) {
      if (msg.role === 'assistant') {
        const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
        for (const tc of toolUses) {
          // Only remap IDs that don't look like OpenAI format (call_*)
          if (!idMapping.has(tc.id) && !tc.id.startsWith('call_')) {
            idMapping.set(tc.id, `call_remap_${idCounter++}`);
          }
        }
      }
    }

    // Second pass: convert messages with remapped IDs
    for (const msg of context.messages) {
      if (msg.role === 'user') {
        const text = typeof msg.content === 'string'
          ? msg.content
          : msg.content
              .filter(c => c.type === 'text')
              .map(c => (c as TextContent).text)
              .join('\n');

        if (text) {
          // ChatGPT backend API requires 'message' type, not 'input_text'
          input.push({
            type: 'message',
            role: 'user',
            content: [{ type: 'input_text', text }],
          });
        }
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
            call_id: idMapping.get(tc.id) ?? tc.id,
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
          call_id: idMapping.get(msg.toolCallId) ?? msg.toolCallId,
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
