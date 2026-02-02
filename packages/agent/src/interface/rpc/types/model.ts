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
  }>;
}
