/**
 * @fileoverview Google Gemini Provider
 *
 * Core provider implementation for Gemini models with:
 * - OAuth authentication (Cloud Code Assist / Antigravity - PREFERRED)
 * - API key authentication (fallback)
 * - Function/tool calling
 * - Streaming responses
 * - Thinking mode support (thinkingLevel for Gemini 3, thinkingBudget for Gemini 2.5)
 * - Safety settings for agentic use
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ThinkingContent,
  ToolCall,
} from '../../types/index.js';
import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import {
  withProviderRetry,
  type StreamRetryConfig,
  mapGoogleStopReason,
} from '../base/index.js';
import {
  refreshGoogleOAuthToken,
  shouldRefreshGoogleTokens,
  discoverGoogleProject,
  CLOUD_CODE_ASSIST_CONFIG,
  ANTIGRAVITY_CONFIG,
} from '../../auth/google-oauth.js';
import { saveProviderOAuthTokens, saveProviderAuth, getProviderAuthSync } from '../../auth/unified.js';
import type {
  GoogleConfig,
  GoogleStreamOptions,
  GoogleProviderAuth,
  GoogleOAuthAuth,
  GeminiStreamChunk,
  SafetyRating,
} from './types.js';
import {
  GEMINI_MODELS,
  DEFAULT_SAFETY_SETTINGS,
  isGemini3Model,
} from './types.js';
import { convertMessages, convertTools } from './message-converter.js';

const logger = createLogger('google');

// =============================================================================
// Provider Class
// =============================================================================

export class GoogleProvider {
  readonly id = 'google';
  private config: GoogleConfig;
  private baseURL: string;
  private retryConfig: StreamRetryConfig | false;
  /** Current auth state (may be mutated during token refresh) */
  private auth: GoogleProviderAuth;

  constructor(config: GoogleConfig) {
    this.config = config;
    this.auth = config.auth;

    // For OAuth, ensure we have the correct endpoint and projectId from stored auth
    // This handles the case where these values aren't passed through the config chain
    if (config.auth.type === 'oauth') {
      let endpoint = config.auth.endpoint;
      let projectId = config.auth.projectId;

      // If endpoint or projectId not in config, try to load from stored auth
      if (!endpoint || !projectId) {
        try {
          const storedAuth = getProviderAuthSync('google');
          if (!endpoint) {
            endpoint = (storedAuth as GoogleOAuthAuth | null)?.endpoint;
          }
          if (!projectId) {
            projectId = (storedAuth as GoogleOAuthAuth | null)?.projectId;
          }
          logger.debug('Loaded auth metadata from stored auth', { endpoint, projectId });
        } catch (e) {
          const structured = categorizeError(e, { operation: 'loadAuthMetadata' });
          logger.debug('Could not load auth metadata from stored auth', {
            code: structured.code,
            category: LogErrorCategory.PROVIDER_AUTH,
          });
        }
      }

      // Default to cloud-code-assist if still not set
      endpoint = endpoint ?? 'cloud-code-assist';

      // Update the auth with the resolved values
      this.auth = {
        ...config.auth,
        endpoint,
        projectId,
      };

      this.baseURL = endpoint === 'antigravity'
        ? ANTIGRAVITY_CONFIG.apiEndpoint
        : CLOUD_CODE_ASSIST_CONFIG.apiEndpoint;

      logger.info('Google provider initialized with OAuth', {
        model: config.model,
        endpoint,
        projectId: projectId ? `${projectId.slice(0, 10)}...` : 'none',
        baseURL: this.baseURL,
      });
    } else {
      this.baseURL = config.baseURL || 'https://generativelanguage.googleapis.com/v1beta';

      logger.info('Google provider initialized with API key', {
        model: config.model,
      });
    }

    // Default to enabled retry with 3 attempts
    this.retryConfig = config.retry ?? { maxRetries: 3 };
  }

  /**
   * Get the model ID
   */
  get model(): string {
    return this.config.model;
  }

  /**
   * Check if OAuth tokens need refresh
   */
  private shouldRefreshTokens(): boolean {
    if (this.auth.type !== 'oauth') return false;
    return shouldRefreshGoogleTokens({
      accessToken: this.auth.accessToken,
      refreshToken: this.auth.refreshToken,
      expiresAt: this.auth.expiresAt,
    });
  }

  /**
   * Ensure we have a valid project ID for OAuth requests
   *
   * This calls the loadCodeAssist API to discover the user's project ID,
   * which is REQUIRED for the x-goog-user-project header.
   */
  private async ensureProjectId(): Promise<void> {
    if (this.auth.type !== 'oauth') return;
    if (this.auth.projectId) return; // Already have projectId

    const endpoint = this.auth.endpoint ?? 'cloud-code-assist';
    logger.info('Discovering Google project ID for OAuth', { endpoint });

    try {
      const projectId = await discoverGoogleProject(this.auth.accessToken, endpoint);

      if (projectId) {
        // Update local state
        this.auth = {
          ...this.auth,
          projectId,
        };

        // Persist the discovered projectId
        const storedAuth = getProviderAuthSync('google');
        if (storedAuth) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          await saveProviderAuth('google', {
            ...storedAuth,
            projectId,
          } as any);
        }

        logger.info('Google project ID discovered and saved', {
          projectId: projectId.slice(0, 15) + '...',
        });
      } else {
        logger.warn('Could not discover Google project ID - requests may fail');
      }
    } catch (error) {
      const structured = categorizeError(error, { endpoint, operation: 'discoverGoogleProject' });
      logger.error('Failed to discover Google project ID', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_API,
        error: structured.message,
        retryable: structured.retryable,
      });
      // Don't throw - let the request proceed and potentially fail with a clearer error
    }
  }

  /**
   * Refresh OAuth tokens if needed
   */
  private async ensureValidTokens(): Promise<void> {
    if (this.auth.type !== 'oauth') return;
    if (!this.shouldRefreshTokens()) return;

    logger.info('Refreshing Google OAuth tokens');

    const endpoint = this.auth.endpoint ?? 'cloud-code-assist';
    try {
      const projectId = this.auth.projectId; // Preserve existing projectId
      const newTokens = await refreshGoogleOAuthToken(this.auth.refreshToken, endpoint);

      // Update local state - PRESERVE projectId
      this.auth = {
        type: 'oauth',
        accessToken: newTokens.accessToken,
        refreshToken: newTokens.refreshToken,
        expiresAt: newTokens.expiresAt,
        endpoint,
        projectId, // Keep the existing projectId
      };

      // Persist refreshed tokens
      await saveProviderOAuthTokens('google', newTokens);

      logger.info('Google OAuth tokens refreshed successfully');
    } catch (error) {
      const structured = categorizeError(error, { endpoint, operation: 'refreshGoogleOAuthToken' });
      logger.error('Failed to refresh Google OAuth tokens', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw new Error(`Failed to refresh Google OAuth tokens: ${structured.message}`);
    }
  }

  /**
   * Get the API URL for a request
   *
   * OAuth endpoints (Cloud Code Assist / Antigravity) use internal path format:
   *   /v1internal:action (model is passed in request body)
   *
   * API key endpoints use standard Gemini API path:
   *   /v1beta/models/{model}:action?key=...
   */
  private getApiUrl(action: 'streamGenerateContent' | 'countTokens' | 'generateContent'): string {
    const model = this.config.model;

    if (this.auth.type === 'oauth') {
      const endpoint = this.auth.endpoint ?? 'cloud-code-assist';
      const apiEndpoint = endpoint === 'antigravity'
        ? ANTIGRAVITY_CONFIG.apiEndpoint
        : CLOUD_CODE_ASSIST_CONFIG.apiEndpoint;
      const apiVersion = endpoint === 'antigravity'
        ? ANTIGRAVITY_CONFIG.apiVersion
        : CLOUD_CODE_ASSIST_CONFIG.apiVersion;
      const streamParam = action === 'streamGenerateContent' ? '?alt=sse' : '';
      // OAuth (Cloud Code Assist) uses /:action path - model is in request body
      return `${apiEndpoint}/${apiVersion}:${action}${streamParam}`;
    } else {
      // API key path uses standard models/{model}:action path
      return `${this.baseURL}/models/${model}:${action}?key=${this.auth.apiKey}&alt=sse`;
    }
  }

  /**
   * Get headers for API request
   *
   * Headers differ between endpoints:
   * - Antigravity: Uses specific User-Agent, X-Goog-Api-Client, Client-Metadata
   *   Does NOT use x-goog-user-project (causes SERVICE_DISABLED errors)
   * - Cloud Code Assist: Uses x-goog-user-project header
   */
  private getHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    if (this.auth.type === 'oauth') {
      headers['Authorization'] = `Bearer ${this.auth.accessToken}`;
      const endpoint = this.auth.endpoint ?? 'cloud-code-assist';

      if (endpoint === 'antigravity') {
        // Antigravity-specific headers - do NOT include x-goog-user-project
        headers['Accept'] = 'text/event-stream';
        headers['User-Agent'] = 'antigravity/1.11.5 darwin/amd64';
        headers['X-Goog-Api-Client'] = 'google-cloud-sdk vscode_cloudshelleditor/0.1';
        headers['Client-Metadata'] = JSON.stringify({
          ideType: 'IDE_UNSPECIFIED',
          platform: 'PLATFORM_UNSPECIFIED',
          pluginType: 'GEMINI',
        });
      } else {
        // Cloud Code Assist headers
        headers['User-Agent'] = 'tron-ai-agent/1.0.0';
        headers['X-Goog-Api-Client'] = 'gl-node/22.0.0';
        // x-goog-user-project is REQUIRED for Cloud Code Assist OAuth
        if (this.auth.projectId) {
          headers['x-goog-user-project'] = this.auth.projectId;
        }
      }
    } else {
      // API key - standard headers
      headers['User-Agent'] = 'tron-ai-agent/1.0.0';
      headers['X-Goog-Api-Client'] = 'gl-node/22.0.0';
    }

    return headers;
  }

  /**
   * Map standard Gemini model names to Antigravity model names
   *
   * Antigravity uses different model identifiers:
   * - gemini-3-pro-high (high thinking)
   * - gemini-3-pro-low (low thinking)
   * - claude-sonnet-4-5
   * - claude-sonnet-4-5-thinking
   * - claude-opus-4-5-thinking
   */
  private mapToAntigravityModel(model: string): string {
    // Map standard Gemini model names to Antigravity equivalents
    const modelMap: Record<string, string> = {
      'gemini-3-pro-preview': 'gemini-3-pro-high',
      'gemini-3-flash-preview': 'gemini-3-pro-low',
      'gemini-2.5-pro': 'gemini-2.5-pro',
      'gemini-2.5-flash': 'gemini-2.5-flash',
    };

    return modelMap[model] || model;
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
   * Stream a response from Gemini with automatic retry on transient failures
   */
  async *stream(
    context: Context,
    options: GoogleStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    // Ensure OAuth tokens are valid before starting
    await this.ensureValidTokens();

    // Ensure we have a valid project ID for OAuth (discovered via loadCodeAssist API)
    await this.ensureProjectId();

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
    options: GoogleStreamOptions = {}
  ): AsyncGenerator<StreamEvent> {
    const model = this.config.model;
    const maxTokens = options.maxTokens ?? this.config.maxTokens ?? 4096;
    const isGemini3 = isGemini3Model(model);

    // Determine temperature - Gemini 3 MUST use temperature=1.0
    let temperature = options.temperature ?? this.config.temperature;
    if (isGemini3 && temperature !== undefined && temperature !== 1.0) {
      logger.warn('Gemini 3 requires temperature=1.0, overriding configured value', {
        configuredTemp: temperature,
        model,
      });
      temperature = 1.0;
    }

    logger.debug('Starting stream', {
      model,
      maxTokens,
      messageCount: context.messages.length,
      toolCount: context.tools?.length ?? 0,
      isGemini3,
    });

    yield { type: 'start' };

    try {
      // Convert messages to Gemini format
      const contents = convertMessages(context);
      const tools = context.tools ? convertTools(context.tools) : undefined;

      // Build generation config
      const generationConfig: Record<string, unknown> = {
        maxOutputTokens: maxTokens,
        ...(temperature !== undefined && { temperature }),
        ...(options.topP !== undefined && { topP: options.topP }),
        ...(options.topK !== undefined && { topK: options.topK }),
        ...(options.stopSequences?.length && { stopSequences: options.stopSequences }),
      };

      // Add thinking config based on model version
      const modelInfo = GEMINI_MODELS[model];
      const thinkingLevel = options.thinkingLevel ?? this.config.thinkingLevel ?? modelInfo?.defaultThinkingLevel;
      const thinkingBudget = options.thinkingBudget ?? this.config.thinkingBudget;

      if (isGemini3 && thinkingLevel) {
        // Gemini 3 uses thinkingLevel (discrete levels)
        // includeThoughts: true enables thought summaries in the response
        (generationConfig as Record<string, unknown>).thinkingConfig = {
          thinkingLevel: thinkingLevel.toUpperCase(), // API expects MINIMAL, LOW, MEDIUM, HIGH
          includeThoughts: true,
        };
      } else if (!isGemini3 && thinkingBudget !== undefined) {
        // Gemini 2.5 uses thinkingBudget (token count 0-32768)
        (generationConfig as Record<string, unknown>).thinkingConfig = {
          thinkingBudget,
          includeThoughts: true,
        };
      }

      // Build request body - format differs between OAuth endpoints and API key
      let body: Record<string, unknown>;

      if (this.auth.type === 'oauth') {
        const endpoint = this.auth.endpoint ?? 'cloud-code-assist';

        // Build the inner request object (common Gemini format)
        const innerRequest: Record<string, unknown> = {
          contents,
          generationConfig,
          // Safety settings - default to OFF for agentic use
          safetySettings: this.config.safetySettings ?? DEFAULT_SAFETY_SETTINGS,
        };

        // Add system instruction if provided
        if (context.systemPrompt) {
          innerRequest.systemInstruction = {
            parts: [{ text: context.systemPrompt }],
          };
        }

        if (tools && tools.length > 0) {
          innerRequest.tools = tools;
        }

        if (endpoint === 'antigravity') {
          // Antigravity uses wrapped request format with project/model at top level
          // Model names differ from standard Gemini API:
          //   gemini-3-pro-preview -> gemini-3-pro-high
          //   gemini-3-flash-preview -> gemini-3-pro-low
          const antigravityModel = this.mapToAntigravityModel(model);

          body = {
            project: this.auth.projectId || '',
            model: antigravityModel,
            request: innerRequest,
            requestType: 'agent',
            userAgent: 'antigravity',
            requestId: `agent-${crypto.randomUUID()}`,
          };
        } else {
          // Cloud Code Assist uses standard format with model in body
          body = {
            ...innerRequest,
            model: `models/${model}`,
          };
        }
      } else {
        // API key - standard Gemini API format
        body = {
          contents,
          generationConfig,
          safetySettings: this.config.safetySettings ?? DEFAULT_SAFETY_SETTINGS,
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
      }

      // Make streaming request
      const url = this.getApiUrl('streamGenerateContent');
      const headers = this.getHeaders();

      logger.debug('Making Gemini API request', {
        url,
        authType: this.auth.type,
        endpoint: this.auth.type === 'oauth' ? this.auth.endpoint : 'api-key',
      });

      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        const errorText = await response.text();
        // Trace log full error response for debugging
        logger.trace('Gemini API error response - full details', {
          statusCode: response.status,
          statusText: response.statusText,
          errorBody: errorText,
          requestUrl: url,
          authType: this.auth.type,
          endpoint: this.auth.type === 'oauth' ? this.auth.endpoint : 'api-key',
          requestContext: {
            model: this.config.model,
            messageCount: context.messages.length,
            hasTools: !!context.tools?.length,
          },
        });

        // Parse error message for better user feedback
        let errorMessage = `Gemini API error: ${response.status}`;
        if (response.status === 404) {
          errorMessage += ` - Model "${model}" not found at endpoint. `;
          if (this.auth.type === 'oauth') {
            errorMessage += `Try a different model or re-authenticate with 'antigravity' endpoint for broader model access.`;
          }
        } else if (response.status === 401 || response.status === 403) {
          errorMessage += ' - Authentication failed. Please re-authenticate with Google OAuth.';
        } else {
          // Try to parse JSON error
          try {
            const errorJson = JSON.parse(errorText);
            if (errorJson.error?.message) {
              errorMessage += ` - ${errorJson.error.message}`;
            } else {
              errorMessage += ` - ${errorText.slice(0, 200)}`;
            }
          } catch {
            // Not JSON, use raw text (truncated)
            errorMessage += ` - ${errorText.slice(0, 200)}`;
          }
        }
        throw new Error(errorMessage);
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
      const toolCalls: Array<{ id: string; name: string; args: Record<string, unknown>; thoughtSignature?: string }> = [];
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;
      let thinkingStarted = false;
      let toolCallIndex = 0;
      // Generate a unique prefix for this streaming response to avoid ID collisions across turns
      // Other providers (Anthropic, OpenAI) return globally unique IDs from the API
      // But Gemini doesn't provide IDs, so we must generate them ourselves
      const uniquePrefix = Math.random().toString(36).substring(2, 10);

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
            if (!candidate?.content?.parts) {
              // Handle finish reason without content (e.g., SAFETY block)
              if (candidate?.finishReason === 'SAFETY') {
                const safetyRatings = candidate.safetyRatings ?? [];
                const blockedCategories = safetyRatings
                  .filter((r: SafetyRating) => r.probability === 'HIGH' || r.probability === 'MEDIUM')
                  .map((r: SafetyRating) => r.category);

                yield {
                  type: 'safety_block',
                  blockedCategories,
                  error: new Error('Response blocked by safety filters'),
                } as StreamEvent;
                continue;
              }
              continue;
            }

            for (const part of candidate.content.parts) {
              // Handle thinking content (thought: true)
              if ('text' in part && part.thought === true) {
                if (!thinkingStarted) {
                  thinkingStarted = true;
                  yield { type: 'thinking_start' };
                }
                accumulatedThinking += part.text;
                yield { type: 'thinking_delta', delta: part.text };
                continue;
              }

              // Handle regular text content
              if ('text' in part && !part.thought) {
                // End thinking if we were in thinking mode
                if (thinkingStarted) {
                  yield { type: 'thinking_end', thinking: accumulatedThinking };
                  thinkingStarted = false;
                }

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
                const id = `call_${uniquePrefix}_${toolCallIndex++}`;
                // thoughtSignature is at the part level, not inside functionCall
                const thoughtSig = (part as { thoughtSignature?: string }).thoughtSignature;

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
                  // Capture thoughtSignature for Gemini 3 multi-turn function calling
                  thoughtSignature: thoughtSig,
                });

                const toolCall: ToolCall = {
                  type: 'tool_use',
                  id,
                  name: fc.name,
                  arguments: fc.args,
                  // Include thoughtSignature so it's preserved in events
                  thoughtSignature: thoughtSig,
                };
                yield { type: 'toolcall_end', toolCall };
              }
            }

            // Handle finish
            if (candidate.finishReason) {
              // End thinking if still active
              if (thinkingStarted) {
                yield { type: 'thinking_end', thinking: accumulatedThinking };
                thinkingStarted = false;
              }

              // Handle SAFETY finish reason
              if (candidate.finishReason === 'SAFETY') {
                const safetyRatings = candidate.safetyRatings ?? [];
                const blockedCategories = safetyRatings
                  .filter((r: SafetyRating) => r.probability === 'HIGH' || r.probability === 'MEDIUM')
                  .map((r: SafetyRating) => r.category);

                yield {
                  type: 'safety_block',
                  blockedCategories,
                  error: new Error('Response blocked by safety filters'),
                } as StreamEvent;
                continue;
              }

              // Emit text_end if we had text
              if (textStarted) {
                yield { type: 'text_end', text: accumulatedText };
              }

              // Build final message - include thinking content if accumulated
              const content: (TextContent | ThinkingContent | ToolCall)[] = [];
              if (accumulatedThinking) {
                content.push({ type: 'thinking', thinking: accumulatedThinking });
              }
              if (accumulatedText) {
                content.push({ type: 'text', text: accumulatedText });
              }
              for (const tc of toolCalls) {
                content.push({
                  type: 'tool_use',
                  id: tc.id,
                  name: tc.name,
                  arguments: tc.args,
                  // Preserve thought_signature for Gemini 3 multi-turn conversations
                  ...(tc.thoughtSignature && { thoughtSignature: tc.thoughtSignature }),
                });
              }

              const message: AssistantMessage = {
                role: 'assistant',
                content,
                usage: { inputTokens, outputTokens, providerType: 'google' as const },
                stopReason: mapGoogleStopReason(candidate.finishReason),
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
      // Trace log full error details for debugging
      logger.trace('Gemini stream error - full details', {
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
      logger.error('Stream error', error instanceof Error ? error : new Error(String(error)));
      yield { type: 'error', error: error instanceof Error ? error : new Error(String(error)) };
    }
  }
}
