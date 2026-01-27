/**
 * @fileoverview Google Provider Types and Constants
 *
 * Defines authentication, configuration, and model constants for the Google Gemini provider.
 */

import type { StreamRetryConfig } from '../base/index.js';

// =============================================================================
// Thinking Types
// =============================================================================

/**
 * Gemini 3 thinking levels (discrete levels for Gemini 3.x models)
 */
export type GeminiThinkingLevel = 'minimal' | 'low' | 'medium' | 'high';

// =============================================================================
// Safety Types
// =============================================================================

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
 * Safety rating probability from API response
 */
export type HarmProbability = 'NEGLIGIBLE' | 'LOW' | 'MEDIUM' | 'HIGH';

/**
 * Safety rating returned by API
 */
export interface SafetyRating {
  category: HarmCategory;
  probability: HarmProbability;
}

/**
 * Safety setting for a specific harm category
 */
export interface SafetySetting {
  category: HarmCategory;
  threshold: HarmBlockThreshold;
}

/**
 * Default safety settings for agentic use (all categories OFF)
 */
export const DEFAULT_SAFETY_SETTINGS: SafetySetting[] = [
  { category: 'HARM_CATEGORY_HARASSMENT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_HATE_SPEECH', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_SEXUALLY_EXPLICIT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_DANGEROUS_CONTENT', threshold: 'OFF' },
  { category: 'HARM_CATEGORY_CIVIC_INTEGRITY', threshold: 'OFF' },
];

// =============================================================================
// Authentication Types
// =============================================================================

/**
 * OAuth authentication for Google (PREFERRED)
 */
export interface GoogleOAuthAuth {
  type: 'oauth';
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  /** Which OAuth endpoint was used */
  endpoint?: 'cloud-code-assist' | 'antigravity';
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

// =============================================================================
// Configuration Types
// =============================================================================

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

// =============================================================================
// Gemini API Types (internal)
// =============================================================================

/**
 * Gemini API content format
 */
export interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

export type GeminiPart =
  | { text: string; thought?: boolean; thoughtSignature?: string }
  | { functionCall: { name: string; args: Record<string, unknown> }; thoughtSignature?: string }
  | { functionResponse: { name: string; response: Record<string, unknown> } };

export interface GeminiTool {
  functionDeclarations: Array<{
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  }>;
}

export interface GeminiStreamChunk {
  candidates?: Array<{
    content?: {
      parts?: GeminiPart[];
      role?: string;
    };
    finishReason?: string;
    safetyRatings?: SafetyRating[];
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
    defaultThinkingLevel: 'high',
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
    defaultThinkingLevel: 'high',
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
    defaultThinkingLevel: 'high',
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
};

export type GeminiModelId = keyof typeof GEMINI_MODELS;

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Check if a model is Gemini 3 (uses thinkingLevel instead of thinkingBudget)
 */
export function isGemini3Model(model: string): boolean {
  return model.includes('gemini-3');
}
