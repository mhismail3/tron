/**
 * @fileoverview OpenAI Provider Types
 *
 * All type definitions for the OpenAI provider including:
 * - Configuration types
 * - Responses API types
 * - Model definitions
 */

import type { StreamRetryConfig } from '../base/index.js';

// =============================================================================
// Configuration Types
// =============================================================================

/**
 * Reasoning effort levels for OpenAI models
 */
export type ReasoningEffort = 'low' | 'medium' | 'high' | 'xhigh';

/**
 * OAuth authentication for OpenAI
 */
export interface OpenAIOAuth {
  type: 'oauth';
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

/**
 * API settings for OpenAI provider (from global settings)
 */
export interface OpenAIApiSettings {
  baseUrl?: string;
  tokenUrl?: string;
  clientId?: string;
  tokenExpiryBufferSeconds?: number;
  defaultReasoningEffort?: ReasoningEffort;
}

/**
 * Configuration for OpenAI provider
 */
export interface OpenAIConfig {
  model: string;
  auth: OpenAIOAuth;
  maxTokens?: number;
  temperature?: number;
  baseURL?: string;
  reasoningEffort?: ReasoningEffort;
  /** Retry configuration for transient failures (default: enabled with 3 retries) */
  retry?: StreamRetryConfig | false;
  /** Optional settings for dependency injection (falls back to global settings) */
  openaiSettings?: OpenAIApiSettings;
}

/**
 * Options for streaming requests
 */
export interface OpenAIStreamOptions {
  maxTokens?: number;
  temperature?: number;
  reasoningEffort?: ReasoningEffort;
  stopSequences?: string[];
}

// =============================================================================
// Responses API Types
// =============================================================================

/**
 * Input item for Responses API
 */
export type ResponsesInputItem =
  | { type: 'input_text'; text: string }
  | { type: 'message'; role: 'user' | 'assistant'; content: MessageContent[]; id?: string }
  | { type: 'function_call'; id?: string; call_id: string; name: string; arguments: string }
  | { type: 'function_call_output'; call_id: string; output: string };

/**
 * Input image content for multimodal messages (Responses API format)
 * Note: image_url is a string (URL or data URL), not an object
 */
export interface OpenAIInputImage {
  type: 'input_image';
  image_url: string;  // URL or data:mime;base64,... format
  detail?: 'auto' | 'low' | 'high';
}

export type MessageContent =
  | { type: 'output_text'; text: string }
  | { type: 'input_text'; text: string }
  | OpenAIInputImage;

/**
 * Tool definition for Responses API
 */
export interface ResponsesTool {
  type: 'function';
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

/**
 * Output item from Responses API (shared between item and response.output)
 */
export interface ResponsesOutputItem {
  type: 'function_call' | 'message' | 'reasoning' | string;
  id?: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  content?: Array<{ type: string; text?: string }>;
  summary?: Array<{ type: string; text?: string }>;
}

/**
 * SSE event types from Responses API
 */
export interface ResponsesStreamEvent {
  type: string;
  /** For response.output_text.delta and response.reasoning_summary_text.delta */
  delta?: string;
  /** For reasoning_summary_text.delta and reasoning_text.delta */
  summary_index?: number;
  content_index?: number;
  /** For response.output_item.added */
  item?: ResponsesOutputItem;
  /** For response.function_call_arguments.delta */
  call_id?: string;
  /** For response.completed */
  response?: {
    id: string;
    output: ResponsesOutputItem[];
    usage?: {
      input_tokens: number;
      output_tokens: number;
    };
  };
}

// =============================================================================
// Model Constants
// =============================================================================

export const OPENAI_MODELS = {
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

export type OpenAIModelId = keyof typeof OPENAI_MODELS;
