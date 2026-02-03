/**
 * @fileoverview Token Module Types
 *
 * Immutable data structures for tracking token usage throughout the system.
 * Follows the principle: Provider API responses are the SOLE source of truth.
 *
 * Design principles:
 * 1. Zero-Assumption Source of Truth - All values originate from provider API responses
 * 2. Immutable TokenRecord - Complete audit trail with source, computed, and metadata
 * 3. Fail-Visible Design - Missing/zero tokens throw errors, not silent 0s
 */

// =============================================================================
// Provider Type (re-export for convenience)
// =============================================================================

export type ProviderType = 'anthropic' | 'openai' | 'openai-codex' | 'google';

// =============================================================================
// Token Source (Raw Values from Provider)
// =============================================================================

/**
 * Raw token values directly extracted from provider API response.
 * These values are IMMUTABLE once extracted - never modify source values.
 */
export interface TokenSource {
  /** Provider that generated these tokens */
  readonly provider: ProviderType;

  /** ISO8601 timestamp when extracted from API response */
  readonly timestamp: string;

  /** Raw input tokens as reported by provider */
  readonly rawInputTokens: number;

  /** Raw output tokens as reported by provider */
  readonly rawOutputTokens: number;

  /**
   * Tokens read from cache (Anthropic/OpenAI).
   * For Anthropic: These are part of the context window.
   * For OpenAI: Informational only.
   */
  readonly rawCacheReadTokens: number;

  /**
   * Tokens written to cache (Anthropic only).
   * IMPORTANT: This is a BILLING indicator, NOT additional context!
   * It tells you how many inputTokens are being written to cache (costs 25% more).
   */
  readonly rawCacheCreationTokens: number;
}

// =============================================================================
// Computed Tokens (Derived from Source)
// =============================================================================

/** Method used to calculate context window tokens */
export type CalculationMethod = 'anthropic_cache_aware' | 'direct';

/**
 * Computed token values derived from source values.
 * These can be recalculated from source + previousBaseline.
 */
export interface ComputedTokens {
  /**
   * Total context window size in tokens.
   *
   * Calculation varies by provider:
   * - Anthropic: inputTokens + cacheReadTokens + cacheCreationTokens
   *   (these three are mutually exclusive, no double counting)
   * - OpenAI/Google: inputTokens (already includes full context)
   */
  readonly contextWindowTokens: number;

  /**
   * Per-turn NEW tokens (for stats line display).
   *
   * Calculation:
   * - First turn: equals contextWindowTokens (all are "new")
   * - Subsequent: contextWindowTokens - previousContextBaseline
   * - Context shrink: 0 (with logged warning)
   */
  readonly newInputTokens: number;

  /** Baseline used for delta calculation (from previous turn) */
  readonly previousContextBaseline: number;

  /** Method used for context window calculation */
  readonly calculationMethod: CalculationMethod;
}

// =============================================================================
// Token Metadata
// =============================================================================

/**
 * Metadata about a token record for audit trail.
 */
export interface TokenMeta {
  /** Turn number within the session */
  readonly turn: number;

  /** Session ID this record belongs to */
  readonly sessionId: string;

  /** ISO8601 timestamp when tokens were extracted from API */
  readonly extractedAt: string;

  /** ISO8601 timestamp when normalization was computed */
  readonly normalizedAt: string;
}

// =============================================================================
// Token Record (Complete Immutable Record)
// =============================================================================

/**
 * Complete immutable token record from a single turn.
 *
 * This is the primary data structure that flows through the system.
 * Once created, it should NEVER be mutated.
 */
export interface TokenRecord {
  /** Source values directly from provider (immutable) */
  readonly source: TokenSource;

  /** Computed values derived from source */
  readonly computed: ComputedTokens;

  /** Metadata about this record */
  readonly meta: TokenMeta;
}

// =============================================================================
// Accumulated Tokens (Session Totals)
// =============================================================================

/**
 * Accumulated token totals across all turns in a session.
 * Used for billing summaries and session-level tracking.
 */
export interface AccumulatedTokens {
  /** Total input tokens across all turns */
  inputTokens: number;

  /** Total output tokens across all turns */
  outputTokens: number;

  /** Total cache read tokens across all turns */
  cacheReadTokens: number;

  /** Total cache creation tokens across all turns */
  cacheCreationTokens: number;

  /** Total cost across all turns */
  cost: number;
}

// =============================================================================
// Context Window State
// =============================================================================

/**
 * Current state of the context window.
 */
export interface ContextWindowState {
  /** Current context size in tokens (from most recent turn) */
  currentSize: number;

  /** Maximum context size for current model */
  maxSize: number;

  /** Percentage of context used (0-100) */
  percentUsed: number;

  /** Tokens remaining before hitting limit */
  tokensRemaining: number;
}

// =============================================================================
// Token State (Session-Level Aggregation)
// =============================================================================

/**
 * Complete token state for a session.
 *
 * This is the single source of truth for token tracking.
 * Replaces the previous fragmented tracking systems.
 */
export interface TokenState {
  /** Current turn's record (most recent) */
  current: TokenRecord | null;

  /** Accumulated totals (for billing) */
  accumulated: AccumulatedTokens;

  /** Context window state */
  contextWindow: ContextWindowState;

  /** History of all token records (for audit trail) */
  history: TokenRecord[];
}

// =============================================================================
// Error Types
// =============================================================================

/**
 * Error thrown when token extraction fails.
 * This indicates a provider response was missing expected usage data.
 */
export class TokenExtractionError extends Error {
  readonly provider: ProviderType | undefined;
  readonly turn: number;
  readonly sessionId: string;
  readonly hasPartialData: boolean;

  constructor(
    message: string,
    context: {
      provider?: ProviderType;
      turn: number;
      sessionId: string;
      hasPartialData?: boolean;
    }
  ) {
    super(message);
    this.name = 'TokenExtractionError';
    this.provider = context.provider;
    this.turn = context.turn;
    this.sessionId = context.sessionId;
    this.hasPartialData = context.hasPartialData ?? false;
  }
}

// =============================================================================
// Factory Functions
// =============================================================================

/**
 * Create an empty token state for a new session.
 */
export function createEmptyTokenState(maxContextSize: number = 200_000): TokenState {
  return {
    current: null,
    accumulated: {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
      cost: 0,
    },
    contextWindow: {
      currentSize: 0,
      maxSize: maxContextSize,
      percentUsed: 0,
      tokensRemaining: maxContextSize,
    },
    history: [],
  };
}

/**
 * Create an empty accumulated tokens object.
 */
export function createEmptyAccumulatedTokens(): AccumulatedTokens {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    cost: 0,
  };
}
