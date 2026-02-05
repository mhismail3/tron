/**
 * @fileoverview OpenAI Provider
 *
 * Provides streaming support for OpenAI models with:
 * - OAuth authentication (ChatGPT Plus/Pro subscription)
 * - Reasoning effort parameter support (low/medium/high/xhigh)
 * - Tool/function calling
 * - Streaming responses via Responses API
 */

import { existsSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import type { AssistantMessage, Context, StreamEvent } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { getSettings } from '@infrastructure/settings/index.js';
import { withProviderRetry, type StreamRetryConfig } from '../base/index.js';
import type {
  OpenAIConfig,
  OpenAIStreamOptions,
  OpenAIApiSettings,
} from './types.js';
import { OpenAITokenManager } from './auth.js';
import { convertToResponsesInput, convertTools, generateToolClarificationMessage } from './message-converter.js';
import { parseSSEStream, createStreamState } from './stream-handler.js';
import { sanitizeMessages } from '@core/utils/message-sanitizer.js';

const logger = createLogger('openai');

// =============================================================================
// Default Instructions
// =============================================================================

/**
 * Load system instructions from markdown file.
 * The ChatGPT backend API requires an instructions field - it cannot be omitted.
 * ChatGPT OAuth validates instructions EXACTLY - we cannot modify them at all.
 *
 * Path resolution supports both tsc build (../prompts/) and
 * esbuild production bundle (./prompts/).
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const INSTRUCTIONS_PATH = existsSync(join(__dirname, '..', 'prompts', 'codex-instructions.md'))
  ? join(__dirname, '..', 'prompts', 'codex-instructions.md')
  : join(__dirname, 'prompts', 'codex-instructions.md');
const DEFAULT_INSTRUCTIONS = readFileSync(INSTRUCTIONS_PATH, 'utf-8');

// =============================================================================
// Settings Helper
// =============================================================================

/**
 * Get default OpenAI settings from global settings.
 * Exported for dependency injection - consumers can pass custom settings.
 */
export function getDefaultOpenAISettings(): OpenAIApiSettings | undefined {
  const settings = getSettings();
  return settings.api.openaiCodex;
}

// =============================================================================
// Provider Class
// =============================================================================

export class OpenAIProvider {
  readonly id = 'openai';
  private config: OpenAIConfig;
  private baseURL: string;
  private retryConfig: StreamRetryConfig | false;
  private openaiSettings: OpenAIApiSettings | undefined;
  private tokenManager: OpenAITokenManager;

  constructor(config: OpenAIConfig) {
    this.config = config;
    this.openaiSettings = config.openaiSettings ?? getDefaultOpenAISettings();
    this.baseURL = config.baseURL || this.openaiSettings?.baseUrl || 'https://chatgpt.com/backend-api';
    this.retryConfig = config.retry === false ? false : (config.retry ?? {});
    this.tokenManager = new OpenAITokenManager(config.auth, this.openaiSettings);

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
   * Stream a response from OpenAI with automatic retry on transient failures
   */
  async *stream(
    context: Context,
    options: OpenAIStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    // Ensure tokens are valid before starting (and before each retry)
    await this.tokenManager.ensureValidTokens();

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
    options: OpenAIStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    const model = this.config.model;
    const reasoningEffort = options.reasoningEffort
      ?? this.config.reasoningEffort
      ?? this.openaiSettings?.defaultReasoningEffort
      ?? 'medium';

    logger.debug('Starting OpenAI stream', {
      model,
      reasoningEffort,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
    });

    yield { type: 'start' };

    try {
      const headers = this.tokenManager.buildHeaders();

      // Sanitize messages to guarantee API compliance (handles interrupted tool calls, etc.)
      const sanitized = sanitizeMessages(context.messages);
      const sanitizedContext = { ...context, messages: sanitized.messages };

      // Convert to Responses API format
      const input = convertToResponsesInput(sanitizedContext);
      const tools = context.tools ? convertTools(context.tools) : undefined;

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
      const body: Record<string, unknown> = {
        model,
        input,
        instructions: DEFAULT_INSTRUCTIONS,
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

      logger.trace('OpenAI request body', {
        model,
        inputCount: input.length,
        toolCount: tools?.length ?? 0,
        reasoning: body.reasoning,
      });

      // POST to responses endpoint
      const response = await fetch(`${this.baseURL}/codex/responses`, {
        method: 'POST',
        headers,
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

      const state = createStreamState();
      yield* parseSSEStream(reader, state);

    } catch (error) {
      logger.error('OpenAI stream error', error instanceof Error ? error : new Error(String(error)));
      yield { type: 'error', error: error instanceof Error ? error : new Error(String(error)) };
    }
  }
}
