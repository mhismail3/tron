/**
 * @fileoverview Model RPC Types
 *
 * Types for model management methods.
 */

// =============================================================================
// Model Methods
// =============================================================================

/** Switch model */
export interface ModelSwitchParams {
  sessionId: string;
  model: string;
}

export interface ModelSwitchResult {
  previousModel: string;
  newModel: string;
}

/** List available models */
export interface ModelListParams {
  /** Filter by provider (anthropic, openai, google, openai-codex) */
  provider?: string;
}

export interface ModelListResult {
  models: Array<{
    id: string;
    name: string;
    provider: string;
    contextWindow: number;
    supportsThinking: boolean;
    supportsImages: boolean;
    /** Model tier: opus, sonnet, haiku, flagship, mini, standard */
    tier?: string;
    /** Whether this is a legacy/deprecated model */
    isLegacy?: boolean;
    /** For models with reasoning capability (e.g., OpenAI Codex) */
    supportsReasoning?: boolean;
    /** Available reasoning effort levels (low, medium, high, xhigh) */
    reasoningLevels?: string[];
    /** Default reasoning level */
    defaultReasoningLevel?: string;
    /** Model family (e.g., "Claude 4.6", "GPT-5.3", "Gemini 3") */
    family?: string;
    /** Maximum output tokens */
    maxOutput?: number;
    /** Brief description of the model */
    description?: string;
    /** Input cost per million tokens (USD) */
    inputCostPerMillion?: number;
    /** Output cost per million tokens (USD) */
    outputCostPerMillion?: number;
    /** Whether this is the recommended model in its tier */
    recommended?: boolean;
    /** Release date (YYYY-MM-DD) */
    releaseDate?: string;
  }>;
}
