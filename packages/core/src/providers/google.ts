/**
 * @fileoverview Google Gemini Provider
 *
 * Provides streaming support for Google Gemini models with:
 * - OAuth authentication (Cloud Code Assist / Antigravity - PREFERRED)
 * - API key authentication (fallback)
 * - Function/tool calling
 * - Streaming responses
 * - Thinking mode support (thinkingLevel for Gemini 3, thinkingBudget for Gemini 2.5)
 * - Safety settings for agentic use
 * - Compatible interface with other providers
 *
 * Authentication Priority:
 * 1. OAuth (via Cloud Code Assist or Antigravity) - always preferred
 * 2. API Key - fallback only
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
  TextContent,
  ToolCall,
} from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { withProviderRetry, type StreamRetryConfig } from './base/index.js';
import {
  type GoogleOAuthEndpoint,
  refreshGoogleOAuthToken,
  shouldRefreshGoogleTokens,
  discoverGoogleProject,
  CLOUD_CODE_ASSIST_CONFIG,
  ANTIGRAVITY_CONFIG,
} from '../auth/google-oauth.js';
import { saveProviderOAuthTokens, saveProviderAuth, getProviderAuthSync } from '../auth/unified.js';

const logger = createLogger('google');

// =============================================================================
// Types
// =============================================================================

/**
 * Gemini 3 thinking levels (discrete levels for Gemini 3.x models)
 */
export type GeminiThinkingLevel = 'minimal' | 'low' | 'medium' | 'high';

/**
 * Safety setting category
 */
export type HarmCategory =
  | 'HARM_CATEGORY_HARASSMENT'
  | 'HARM_CATEGORY_HATE_SPEECH'
  | 'HARM_CATEGORY_SEXUALLY_EXPLICIT'
  | 'HARM_CATEGORY_DANGEROUS_CONTENT'
  | 'HARM_CATEGORY_CIVIC_INTEGRITY';

/**
 * Safety setting threshold
 */
export type HarmBlockThreshold =
  | 'BLOCK_NONE'
  | 'BLOCK_ONLY_HIGH'
  | 'BLOCK_MEDIUM_AND_ABOVE'
  | 'BLOCK_LOW_AND_ABOVE'
  | 'OFF';

/**
 * Safety setting for a specific harm category
 */
export interface SafetySetting {
  category: HarmCategory;
  threshold: HarmBlockThreshold;
}

/**
 * OAuth authentication for Google (PREFERRED)
 */
export interface GoogleOAuthAuth {
  type: 'oauth';
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  /** Which OAuth endpoint was used */
  endpoint?: GoogleOAuthEndpoint;
  /** Project ID for x-goog-user-project header (required for Cloud Code Assist) */
  projectId?: string;
}

/**
 * API key authentication for Google (fallback)
 */
export interface GoogleApiKeyAuth {
  type: 'api_key';
  apiKey: string;
}

/**
 * Unified Google auth type - OAuth always takes priority when both are available
 */
export type GoogleProviderAuth = GoogleOAuthAuth | GoogleApiKeyAuth;

/**
 * Configuration for Google provider
 */
export interface GoogleConfig {
  model: string;
  /** Authentication - OAuth is ALWAYS preferred over API key */
  auth: GoogleProviderAuth;
  maxTokens?: number;
  temperature?: number;
  /** Base URL override (only used with API key auth) */
  baseURL?: string;
  /** Thinking level for Gemini 3 models (minimal/low/medium/high) */
  thinkingLevel?: GeminiThinkingLevel;
  /** Thinking budget in tokens for Gemini 2.5 models (0-32768) */
  thinkingBudget?: number;
  /** Custom safety settings (defaults to OFF for agentic use) */
  safetySettings?: SafetySetting[];
  /** Retry configuration for transient failures (default: enabled with 3 retries) */
  retry?: StreamRetryConfig | false;
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
  /** Thinking level for Gemini 3 models */
  thinkingLevel?: GeminiThinkingLevel;
  /** Thinking budget for Gemini 2.5 models */
  thinkingBudget?: number;
}

/**
 * Gemini API content format
 */
interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

type GeminiPart =
  | { text: string; thought?: boolean }
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

/**
 * Gemini model information with thinking support
 */
export interface GeminiModelInfo {
  name: string;
  shortName: string;
  contextWindow: number;
  maxOutput: number;
  supportsTools: boolean;
  /** Whether this model supports thinking mode */
  supportsThinking: boolean;
  /** Tier for UI categorization */
  tier: 'pro' | 'flash' | 'flash-lite';
  /** Whether this is a preview model */
  preview?: boolean;
  /** Default thinking level for Gemini 3 models */
  defaultThinkingLevel?: GeminiThinkingLevel;
  /** Supported thinking levels (for UI) */
  supportedThinkingLevels?: GeminiThinkingLevel[];
  /** Input cost per 1k tokens */
  inputCostPer1k: number;
  /** Output cost per 1k tokens */
  outputCostPer1k: number;
}

export const GEMINI_MODELS: Record<string, GeminiModelInfo> = {
  // Gemini 3 series (December 2025 - latest preview)
  // Note: Gemini 3 uses thinkingLevel instead of thinkingBudget
  // Temperature MUST be 1.0 for Gemini 3 models
  'gemini-3-pro-preview': {
    name: 'Gemini 3 Pro (Preview)',
    shortName: 'Gemini 3 Pro',
    contextWindow: 1048576,
    maxOutput: 65536,
    supportsTools: true,
    supportsThinking: true,
    tier: 'pro',
    preview: true,
    defaultThinkingLevel: 'medium',
    supportedThinkingLevels: ['low', 'medium', 'high'],
    inputCostPer1k: 0.00125,
    outputCostPer1k: 0.005,
  },
  'gemini-3-flash-preview': {
    name: 'Gemini 3 Flash (Preview)',
    shortName: 'Gemini 3 Flash',
    contextWindow: 1048576,
    maxOutput: 65536,
    supportsTools: true,
    supportsThinking: true,
    tier: 'flash',
    preview: true,
    defaultThinkingLevel: 'low',
    supportedThinkingLevels: ['minimal', 'low', 'medium', 'high'],
    inputCostPer1k: 0.000075,
    outputCostPer1k: 0.0003,
  },
  // Gemini 2.5 series (stable production)
  // Note: Gemini 2.5 uses thinkingBudget (0-32768 tokens)
  'gemini-2.5-pro': {
    name: 'Gemini 2.5 Pro',
    shortName: 'Gemini 2.5 Pro',
    contextWindow: 2097152,
    maxOutput: 16384,
    supportsTools: true,
    supportsThinking: true,
    tier: 'pro',
    defaultThinkingLevel: 'medium',
    supportedThinkingLevels: ['low', 'medium', 'high'],
    inputCostPer1k: 0.00125,
    outputCostPer1k: 0.005,
  },
  'gemini-2.5-flash': {
    name: 'Gemini 2.5 Flash',
    shortName: 'Gemini 2.5 Flash',
    contextWindow: 1048576,
    maxOutput: 16384,
    supportsTools: true,
    supportsThinking: true,
    tier: 'flash',
    defaultThinkingLevel: 'low',
    supportedThinkingLevels: ['minimal', 'low', 'medium', 'high'],
    inputCostPer1k: 0.000075,
    outputCostPer1k: 0.0003,
  },
  'gemini-2.5-flash-lite': {
    name: 'Gemini 2.5 Flash Lite',
    shortName: 'Gemini 2.5 Flash Lite',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    supportsThinking: false,
    tier: 'flash-lite',
    inputCostPer1k: 0.0000375,
    outputCostPer1k: 0.00015,
  },
  // Gemini 2.0 series
  'gemini-2.0-flash': {
    name: 'Gemini 2.0 Flash',
    shortName: 'Gemini 2.0 Flash',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    supportsThinking: false,
    tier: 'flash',
    inputCostPer1k: 0.000075,
    outputCostPer1k: 0.0003,
  },
  'gemini-2.0-flash-lite': {
    name: 'Gemini 2.0 Flash Lite',
    shortName: 'Gemini 2.0 Flash Lite',
    contextWindow: 1048576,
    maxOutput: 8192,
    supportsTools: true,
    supportsThinking: false,
    tier: 'flash-lite',
    inputCostPer1k: 0.0000375,
    outputCostPer1k: 0.00015,
  },
};

export type GeminiModelId = keyof typeof GEMINI_MODELS;

// =============================================================================
// Provider Class
// =============================================================================

/**
 * Default safety settings for agentic use (all categories OFF)
 */
const DEFAULT_SAFETY_SETTINGS: SafetySetting[] = [
  { category: 'HARM_CATEGORY_HARASSMENT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_HATE_SPEECH', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_SEXUALLY_EXPLICIT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_DANGEROUS_CONTENT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_CIVIC_INTEGRITY', threshold: 'OFF' },
];

/**
 * Check if a model is Gemini 3 (uses thinkingLevel instead of thinkingBudget)
 */
function isGemini3Model(model: string): boolean {
  return model.includes('gemini-3');
}

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
            endpoint = (storedAuth as any)?.endpoint as GoogleOAuthEndpoint | undefined;
          }
          if (!projectId) {
            projectId = (storedAuth as any)?.projectId as string | undefined;
          }
          logger.debug('Loaded auth metadata from stored auth', { endpoint, projectId });
        } catch (e) {
          logger.debug('Could not load auth metadata from stored auth');
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
      logger.error('Failed to discover Google project ID', { error });
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

    try {
      const endpoint = this.auth.endpoint ?? 'cloud-code-assist';
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
      logger.error('Failed to refresh Google OAuth tokens', { error });
      throw new Error(`Failed to refresh Google OAuth tokens: ${error}`);
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
      const contents = this.convertMessages(context);
      const tools = context.tools ? this.convertTools(context.tools) : undefined;

      // Build generation config
      const generationConfig: Record<string, unknown> = {
        maxOutputTokens: maxTokens,
        ...(temperature !== undefined && { temperature }),
        ...(options.topP !== undefined && { topP: options.topP }),
        ...(options.topK !== undefined && { topK: options.topK }),
        ...(options.stopSequences?.length && { stopSequences: options.stopSequences }),
      };

      // Add thinking config based on model version
      const thinkingLevel = options.thinkingLevel ?? this.config.thinkingLevel;
      const thinkingBudget = options.thinkingBudget ?? this.config.thinkingBudget;

      if (isGemini3 && thinkingLevel) {
        // Gemini 3 uses thinkingLevel (discrete levels)
        generationConfig.thinkingConfig = {
          thinkingLevel: thinkingLevel.toUpperCase(), // API expects MINIMAL, LOW, MEDIUM, HIGH
        };
      } else if (!isGemini3 && thinkingBudget !== undefined) {
        // Gemini 2.5 uses thinkingBudget (token count 0-32768)
        generationConfig.thinkingConfig = {
          thinkingBudget,
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
      const toolCalls: Array<{ id: string; name: string; args: Record<string, unknown> }> = [];
      let inputTokens = 0;
      let outputTokens = 0;
      let textStarted = false;
      let thinkingStarted = false;
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
            if (!candidate?.content?.parts) {
              // Handle finish reason without content (e.g., SAFETY block)
              if (candidate?.finishReason === 'SAFETY') {
                const safetyRatings = (candidate as any).safetyRatings ?? [];
                const blockedCategories = safetyRatings
                  .filter((r: any) => r.probability === 'HIGH' || r.probability === 'MEDIUM')
                  .map((r: any) => r.category);

                yield {
                  type: 'safety_block',
                  blockedCategories,
                  error: new Error('Response blocked by safety filters'),
                };
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
              // End thinking if still active
              if (thinkingStarted) {
                yield { type: 'thinking_end', thinking: accumulatedThinking };
                thinkingStarted = false;
              }

              // Handle SAFETY finish reason
              if (candidate.finishReason === 'SAFETY') {
                const safetyRatings = (candidate as any).safetyRatings ?? [];
                const blockedCategories = safetyRatings
                  .filter((r: any) => r.probability === 'HIGH' || r.probability === 'MEDIUM')
                  .map((r: any) => r.category);

                yield {
                  type: 'safety_block',
                  blockedCategories,
                  error: new Error('Response blocked by safety filters'),
                };
                continue;
              }

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

  /**
   * Convert Tron messages to Gemini format
   *
   * Note: Tool call IDs from other providers are remapped to ensure consistency
   * when switching providers mid-session.
   */
  private convertMessages(context: Context): GeminiContent[] {
    const contents: GeminiContent[] = [];

    // Build a mapping of original tool call IDs to normalized IDs.
    // This is necessary when switching providers mid-session.
    // Only remap IDs that don't already look like the expected format.
    const idMapping = new Map<string, string>();
    let idCounter = 0;

    // First pass: collect tool call IDs that need remapping (non-standard format)
    for (const msg of context.messages) {
      if (msg.role === 'assistant') {
        const toolUses = msg.content.filter((c): c is ToolCall => c.type === 'tool_use');
        for (const tc of toolUses) {
          // Only remap IDs that don't look like call_* format
          if (!idMapping.has(tc.id) && !tc.id.startsWith('call_')) {
            idMapping.set(tc.id, `call_remap_${idCounter++}`);
          }
        }
      }
    }

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
                tool_call_id: idMapping.get(msg.toolCallId) ?? msg.toolCallId,
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
        parameters: this.sanitizeSchemaForGemini(tool.parameters as Record<string, unknown>),
      })),
    }];
  }

  /**
   * Sanitize JSON Schema for Gemini API compatibility.
   * Gemini doesn't support certain JSON Schema properties like additionalProperties.
   */
  private sanitizeSchemaForGemini(schema: Record<string, unknown>): Record<string, unknown> {
    if (!schema || typeof schema !== 'object') {
      return schema;
    }

    const result: Record<string, unknown> = {};

    for (const [key, value] of Object.entries(schema)) {
      // Skip unsupported properties
      if (key === 'additionalProperties' || key === '$schema') {
        continue;
      }

      // Recursively sanitize nested objects
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        result[key] = this.sanitizeSchemaForGemini(value as Record<string, unknown>);
      } else if (Array.isArray(value)) {
        // Sanitize arrays (e.g., items in allOf, anyOf, oneOf)
        result[key] = value.map(item =>
          item && typeof item === 'object'
            ? this.sanitizeSchemaForGemini(item as Record<string, unknown>)
            : item
        );
      } else {
        result[key] = value;
      }
    }

    return result;
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
