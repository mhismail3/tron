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
 *
 * Delegates to:
 * - auth.ts: OAuth token management
 * - stream-handler.ts: SSE parsing
 * - message-converter.ts: Message format conversion
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
} from '../../types/index.js';
import { createLogger } from '../../logging/index.js';
import {
  withProviderRetry,
  type StreamRetryConfig,
} from '../base/index.js';
import {
  CLOUD_CODE_ASSIST_CONFIG,
  ANTIGRAVITY_CONFIG,
} from '../../auth/google-oauth.js';
import type {
  GoogleConfig,
  GoogleStreamOptions,
  GoogleProviderAuth,
  GoogleOAuthAuth,
} from './types.js';
import {
  GEMINI_MODELS,
  DEFAULT_SAFETY_SETTINGS,
  isGemini3Model,
} from './types.js';
import { convertMessages, convertTools } from './message-converter.js';
import {
  loadAuthMetadata,
  ensureValidTokens,
  ensureProjectId,
  shouldRefreshTokens,
} from './auth.js';
import { parseSSEStream, createStreamState } from './stream-handler.js';

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
    if (config.auth.type === 'oauth') {
      this.auth = loadAuthMetadata(config.auth);
      const oauthAuth = this.auth as GoogleOAuthAuth;

      this.baseURL = oauthAuth.endpoint === 'antigravity'
        ? ANTIGRAVITY_CONFIG.apiEndpoint
        : CLOUD_CODE_ASSIST_CONFIG.apiEndpoint;

      logger.info('Google provider initialized with OAuth', {
        model: config.model,
        endpoint: oauthAuth.endpoint,
        projectId: oauthAuth.projectId ? `${oauthAuth.projectId.slice(0, 10)}...` : 'none',
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

  // ===========================================================================
  // URL and Header Helpers
  // ===========================================================================

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
      const oauthAuth = this.auth as GoogleOAuthAuth;
      const endpoint = oauthAuth.endpoint ?? 'cloud-code-assist';
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
      const oauthAuth = this.auth as GoogleOAuthAuth;
      headers['Authorization'] = `Bearer ${oauthAuth.accessToken}`;
      const endpoint = oauthAuth.endpoint ?? 'cloud-code-assist';

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
        if (oauthAuth.projectId) {
          headers['x-goog-user-project'] = oauthAuth.projectId;
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
   */
  private mapToAntigravityModel(model: string): string {
    const modelMap: Record<string, string> = {
      'gemini-3-pro-preview': 'gemini-3-pro-high',
      'gemini-3-flash-preview': 'gemini-3-pro-low',
      'gemini-2.5-pro': 'gemini-2.5-pro',
      'gemini-2.5-flash': 'gemini-2.5-flash',
    };
    return modelMap[model] || model;
  }

  // ===========================================================================
  // Public API
  // ===========================================================================

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
    // Ensure OAuth tokens are valid before starting (delegated to auth.ts)
    if (this.auth.type === 'oauth') {
      if (shouldRefreshTokens(this.auth)) {
        const result = await ensureValidTokens(this.auth as GoogleOAuthAuth);
        if (result.refreshed) {
          this.auth = result.auth;
        }
      }

      // Ensure we have a valid project ID (delegated to auth.ts)
      const oauthAuth = this.auth as GoogleOAuthAuth;
      if (!oauthAuth.projectId) {
        this.auth = await ensureProjectId(oauthAuth);
      }
    }

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

  // ===========================================================================
  // Internal Streaming
  // ===========================================================================

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
      // Build request body
      const body = this.buildRequestBody(context, options, maxTokens, temperature, isGemini3);

      // Make streaming request
      const url = this.getApiUrl('streamGenerateContent');
      const headers = this.getHeaders();

      logger.debug('Making Gemini API request', {
        url,
        authType: this.auth.type,
        endpoint: this.auth.type === 'oauth' ? (this.auth as GoogleOAuthAuth).endpoint : 'api-key',
      });

      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        yield* this.handleErrorResponse(response, context);
        return;
      }

      // Process SSE stream (delegated to stream-handler.ts)
      const reader = response.body?.getReader();
      if (!reader) {
        throw new Error('No response body');
      }

      const state = createStreamState();
      yield* parseSSEStream(reader, state);

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

  // ===========================================================================
  // Request Building
  // ===========================================================================

  /**
   * Build the request body for Gemini API
   */
  private buildRequestBody(
    context: Context,
    options: GoogleStreamOptions,
    maxTokens: number,
    temperature: number | undefined,
    isGemini3: boolean
  ): Record<string, unknown> {
    const model = this.config.model;

    // Convert messages to Gemini format (delegated to message-converter.ts)
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
      generationConfig.thinkingConfig = {
        thinkingLevel: thinkingLevel.toUpperCase(),
        includeThoughts: true,
      };
    } else if (!isGemini3 && thinkingBudget !== undefined) {
      generationConfig.thinkingConfig = {
        thinkingBudget,
        includeThoughts: true,
      };
    }

    // Build request body - format differs between OAuth endpoints and API key
    if (this.auth.type === 'oauth') {
      return this.buildOAuthRequestBody(context, contents, generationConfig, tools, model);
    } else {
      return this.buildApiKeyRequestBody(context, contents, generationConfig, tools);
    }
  }

  /**
   * Build request body for OAuth endpoints
   */
  private buildOAuthRequestBody(
    context: Context,
    contents: ReturnType<typeof convertMessages>,
    generationConfig: Record<string, unknown>,
    tools: ReturnType<typeof convertTools> | undefined,
    model: string
  ): Record<string, unknown> {
    const oauthAuth = this.auth as GoogleOAuthAuth;
    const endpoint = oauthAuth.endpoint ?? 'cloud-code-assist';

    // Build the inner request object (common Gemini format)
    const innerRequest: Record<string, unknown> = {
      contents,
      generationConfig,
      safetySettings: this.config.safetySettings ?? DEFAULT_SAFETY_SETTINGS,
    };

    if (context.systemPrompt) {
      innerRequest.systemInstruction = {
        parts: [{ text: context.systemPrompt }],
      };
    }

    if (tools && tools.length > 0) {
      innerRequest.tools = tools;
    }

    if (endpoint === 'antigravity') {
      const antigravityModel = this.mapToAntigravityModel(model);
      return {
        project: oauthAuth.projectId || '',
        model: antigravityModel,
        request: innerRequest,
        requestType: 'agent',
        userAgent: 'antigravity',
        requestId: `agent-${crypto.randomUUID()}`,
      };
    } else {
      return {
        ...innerRequest,
        model: `models/${model}`,
      };
    }
  }

  /**
   * Build request body for API key endpoint
   */
  private buildApiKeyRequestBody(
    context: Context,
    contents: ReturnType<typeof convertMessages>,
    generationConfig: Record<string, unknown>,
    tools: ReturnType<typeof convertTools> | undefined
  ): Record<string, unknown> {
    const body: Record<string, unknown> = {
      contents,
      generationConfig,
      safetySettings: this.config.safetySettings ?? DEFAULT_SAFETY_SETTINGS,
    };

    if (context.systemPrompt) {
      body.systemInstruction = {
        parts: [{ text: context.systemPrompt }],
      };
    }

    if (tools && tools.length > 0) {
      body.tools = tools;
    }

    return body;
  }

  // ===========================================================================
  // Error Handling
  // ===========================================================================

  /**
   * Handle error response from API
   */
  private async *handleErrorResponse(
    response: Response,
    context: Context
  ): AsyncGenerator<StreamEvent> {
    const model = this.config.model;
    const errorText = await response.text();

    // Trace log full error response for debugging
    logger.trace('Gemini API error response - full details', {
      statusCode: response.status,
      statusText: response.statusText,
      errorBody: errorText,
      requestUrl: response.url,
      authType: this.auth.type,
      endpoint: this.auth.type === 'oauth' ? (this.auth as GoogleOAuthAuth).endpoint : 'api-key',
      requestContext: {
        model,
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
      try {
        const errorJson = JSON.parse(errorText);
        if (errorJson.error?.message) {
          errorMessage += ` - ${errorJson.error.message}`;
        } else {
          errorMessage += ` - ${errorText.slice(0, 200)}`;
        }
      } catch {
        errorMessage += ` - ${errorText.slice(0, 200)}`;
      }
    }

    throw new Error(errorMessage);
  }
}
