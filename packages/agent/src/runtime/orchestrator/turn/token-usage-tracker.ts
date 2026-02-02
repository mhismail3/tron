/**
 * @fileoverview Token Usage Tracker
 *
 * Extracted from TurnContentTracker to handle token normalization,
 * provider type management, and context baseline tracking.
 *
 * ## Key Responsibilities
 *
 * 1. **Provider Type Management** - Different providers report inputTokens differently:
 *    - Anthropic: inputTokens excludes cache, contextWindow = input + cacheRead + cacheCreate
 *    - OpenAI/Codex/Gemini: inputTokens is the full context
 *
 * 2. **Context Baseline Tracking** - Maintains previous context size for delta calculation.
 *    Critical behavior: baseline persists across agent runs but resets on provider change.
 *
 * 3. **Token Normalization** - Provides semantic clarity for different UI components:
 *    - newInputTokens: Per-turn delta (for stats line)
 *    - contextWindowTokens: Total context size (for progress pill)
 *    - rawInputTokens: Provider value (for billing)
 *
 * @see token-normalizer.ts for detailed documentation on provider differences
 */
import { createLogger } from '@infrastructure/logging/index.js';
import type { ProviderType } from '@core/types/messages.js';
import { normalizeTokenUsage, type NormalizedTokenUsage } from '@llm/providers/token-normalizer.js';

const logger = createLogger('token-usage-tracker');

// Re-export NormalizedTokenUsage for convenience
export type { NormalizedTokenUsage } from '@llm/providers/token-normalizer.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Raw token usage from provider API response.
 */
export interface RawTokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}

/**
 * Configuration for TokenUsageTracker.
 */
export interface TokenUsageTrackerConfig {
  /** Initial provider type (default: 'anthropic') */
  initialProviderType?: ProviderType;
}

// =============================================================================
// TokenUsageTracker Class
// =============================================================================

/**
 * Tracks token usage with provider-aware normalization.
 *
 * Key behaviors:
 * - Context baseline persists across turns and agent runs (for accurate deltas)
 * - Baseline resets only when provider type changes
 * - Normalization handles provider semantic differences automatically
 */
export class TokenUsageTracker {
  // ---------------------------------------------------------------------------
  // Provider State
  // ---------------------------------------------------------------------------

  /**
   * Current provider type determines how inputTokens should be interpreted.
   */
  private currentProviderType: ProviderType;

  // ---------------------------------------------------------------------------
  // Baseline State
  // ---------------------------------------------------------------------------

  /**
   * Previous context size for delta calculation.
   *
   * CRITICAL: This persists across agent runs within a session.
   * Only resets when provider type changes.
   *
   * Why? Agent runs start on every user message, but we want consistent
   * delta tracking across the entire session. If we reset on agent start,
   * first turn shows full context while later turns show delta - confusing.
   */
  private previousContextSize: number = 0;

  // ---------------------------------------------------------------------------
  // Per-Recording State (cleared on reset)
  // ---------------------------------------------------------------------------

  /**
   * Last raw token usage from API response.
   */
  private lastRawUsage: RawTokenUsage | undefined;

  /**
   * Last normalized token usage with semantic clarity.
   */
  private lastNormalizedUsage: NormalizedTokenUsage | undefined;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  constructor(config: TokenUsageTrackerConfig = {}) {
    this.currentProviderType = config.initialProviderType ?? 'anthropic';
  }

  // ---------------------------------------------------------------------------
  // Provider Type Management
  // ---------------------------------------------------------------------------

  /**
   * Set the current provider type.
   *
   * IMPORTANT: Changing provider resets the context baseline because
   * different providers interpret inputTokens differently. The previous
   * baseline would be meaningless after a provider switch.
   */
  setProviderType(type: ProviderType): void {
    if (this.currentProviderType !== type) {
      logger.debug('Provider type changed', {
        from: this.currentProviderType,
        to: type,
      });
      this.currentProviderType = type;
      // Reset baseline when provider changes (context interpretation changes)
      this.previousContextSize = 0;
    }
  }

  /**
   * Get the current provider type.
   */
  getProviderType(): ProviderType {
    return this.currentProviderType;
  }

  // ---------------------------------------------------------------------------
  // Token Recording
  // ---------------------------------------------------------------------------

  /**
   * Record token usage from API response.
   *
   * Immediately calculates normalized usage and updates the baseline.
   */
  recordTokenUsage(usage: RawTokenUsage): void {
    // Store raw usage
    this.lastRawUsage = usage;

    // Calculate normalized usage immediately
    this.lastNormalizedUsage = normalizeTokenUsage(
      usage,
      this.currentProviderType,
      this.previousContextSize
    );

    // Update baseline for next recording
    this.previousContextSize = this.lastNormalizedUsage.contextWindowTokens;

    logger.debug('Token usage recorded', {
      providerType: this.currentProviderType,
      rawInputTokens: usage.inputTokens,
      newInputTokens: this.lastNormalizedUsage.newInputTokens,
      contextWindowTokens: this.lastNormalizedUsage.contextWindowTokens,
      baseline: this.previousContextSize,
    });
  }

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------

  /**
   * Get last raw token usage.
   */
  getLastRawUsage(): RawTokenUsage | undefined {
    return this.lastRawUsage;
  }

  /**
   * Get last normalized token usage.
   *
   * Provides semantic clarity for different UI components:
   * - newInputTokens: For stats line (per-turn delta)
   * - contextWindowTokens: For progress pill (total context)
   * - rawInputTokens: For billing/debugging
   */
  getLastNormalizedUsage(): NormalizedTokenUsage | undefined {
    return this.lastNormalizedUsage;
  }

  /**
   * Get the current context baseline.
   *
   * This is the contextWindowTokens from the last recording.
   * Used for debugging and verification.
   */
  getContextBaseline(): number {
    return this.previousContextSize;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle Methods
  // ---------------------------------------------------------------------------

  /**
   * Reset for a new turn.
   *
   * Clears per-turn usage data but preserves:
   * - Provider type
   * - Context baseline (for accurate delta calculation)
   */
  resetForNewTurn(): void {
    this.lastRawUsage = undefined;
    this.lastNormalizedUsage = undefined;
    // NOTE: previousContextSize is intentionally NOT reset
    // NOTE: currentProviderType is intentionally NOT reset
  }

  /**
   * Reset for a new agent run.
   *
   * Clears per-turn usage data but preserves:
   * - Provider type
   * - Context baseline (critical for accurate delta across agent runs)
   *
   * Agent runs start on every user message, but we want consistent
   * delta tracking across the entire session.
   */
  resetForNewAgent(): void {
    this.lastRawUsage = undefined;
    this.lastNormalizedUsage = undefined;
    // NOTE: previousContextSize is intentionally NOT reset here
    // This was a bug that was fixed - see TurnContentTracker comments
    // NOTE: currentProviderType is intentionally NOT reset
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a new TokenUsageTracker instance.
 */
export function createTokenUsageTracker(
  config: TokenUsageTrackerConfig = {}
): TokenUsageTracker {
  return new TokenUsageTracker(config);
}
