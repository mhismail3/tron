/**
 * @fileoverview Token State Manager
 *
 * Manages session-level token tracking state. This is the single source of truth
 * for all token-related data in a session.
 *
 * Key responsibilities:
 * 1. Recording per-turn token usage
 * 2. Accumulating totals for billing
 * 3. Tracking context window state
 * 4. Maintaining history for audit trail
 * 5. Handling provider switches
 * 6. Supporting session resume/restore
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type {
  TokenSource,
  TokenMeta,
  TokenRecord,
  TokenState,
  AccumulatedTokens,
  ProviderType,
} from '../types.js';
import { createEmptyTokenState, createEmptyAccumulatedTokens } from '../types.js';
import { normalizeTokens } from '../normalization/index.js';

const logger = createLogger('token-state-manager');

// =============================================================================
// Configuration
// =============================================================================

/**
 * Configuration for TokenStateManager.
 */
export interface TokenStateManagerConfig {
  /** Maximum context window size for the model (default: 200,000) */
  contextLimit?: number;
}

// =============================================================================
// TokenStateManager Class
// =============================================================================

/**
 * Manages session-level token tracking state.
 *
 * This replaces the previous fragmented token tracking systems with a single,
 * unified state manager that provides:
 * - Immutable TokenRecords for each turn
 * - Accumulated totals for billing
 * - Context window tracking for progress display
 * - Full history for audit trail
 * - Provider-aware normalization
 */
export class TokenStateManager {
  private state: TokenState;
  private currentProviderType: ProviderType = 'anthropic';

  constructor(config: TokenStateManagerConfig = {}) {
    this.state = createEmptyTokenState(config.contextLimit ?? 200_000);
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  /**
   * Record token usage for a turn.
   *
   * @param source - Token source extracted from provider API response
   * @param meta - Metadata for this turn
   * @param cost - Optional cost for this turn
   * @returns The normalized TokenRecord
   */
  recordTurn(source: TokenSource, meta: TokenMeta, cost?: number): TokenRecord {
    // Get previous baseline from current context
    const previousBaseline = this.state.contextWindow.currentSize;

    // Normalize tokens to create immutable record
    const record = normalizeTokens(source, previousBaseline, meta);

    // Update accumulated totals
    this.state.accumulated.inputTokens += source.rawInputTokens;
    this.state.accumulated.outputTokens += source.rawOutputTokens;
    this.state.accumulated.cacheReadTokens += source.rawCacheReadTokens;
    this.state.accumulated.cacheCreationTokens += source.rawCacheCreationTokens;
    this.state.accumulated.cacheCreation5mTokens += source.rawCacheCreation5mTokens;
    this.state.accumulated.cacheCreation1hTokens += source.rawCacheCreation1hTokens;
    this.state.accumulated.cost += cost ?? 0;

    // Update context window state
    this.state.contextWindow.currentSize = record.computed.contextWindowTokens;
    this.updateContextWindowCalculations();

    // Update current and history
    this.state.current = record;
    this.state.history.push(record);

    logger.info('[TOKEN-STATE] Turn recorded', {
      turn: meta.turn,
      provider: source.provider,
      rawInput: source.rawInputTokens,
      rawOutput: source.rawOutputTokens,
      rawCacheRead: source.rawCacheReadTokens,
      rawCacheCreation: source.rawCacheCreationTokens,
      rawCacheCreation5m: source.rawCacheCreation5mTokens,
      rawCacheCreation1h: source.rawCacheCreation1hTokens,
      contextWindow: record.computed.contextWindowTokens,
      newInput: record.computed.newInputTokens,
      accumulatedInput: this.state.accumulated.inputTokens,
      accumulatedCacheRead: this.state.accumulated.cacheReadTokens,
    });

    return record;
  }

  // ---------------------------------------------------------------------------
  // State Access
  // ---------------------------------------------------------------------------

  /**
   * Get the current token state.
   *
   * Returns a copy to prevent external mutation.
   */
  getState(): Readonly<TokenState> {
    return this.state;
  }

  // ---------------------------------------------------------------------------
  // Provider Management
  // ---------------------------------------------------------------------------

  /**
   * Handle provider type change.
   *
   * When provider changes, we reset the context baseline because different
   * providers interpret inputTokens differently. The previous baseline
   * would be meaningless after a provider switch.
   *
   * Note: We preserve accumulated tokens and history.
   */
  onProviderChange(newProviderType: ProviderType): void {
    if (this.currentProviderType !== newProviderType) {
      logger.info('[TOKEN-STATE] Provider changed', {
        from: this.currentProviderType,
        to: newProviderType,
      });
      this.currentProviderType = newProviderType;
      // Reset context baseline for fresh delta calculation
      this.state.contextWindow.currentSize = 0;
      this.updateContextWindowCalculations();
    }
  }

  // ---------------------------------------------------------------------------
  // Context Limit Management
  // ---------------------------------------------------------------------------

  /**
   * Set the maximum context window size.
   *
   * This should be called when the model changes or when we get
   * updated model information from the server.
   */
  setContextLimit(limit: number): void {
    this.state.contextWindow.maxSize = limit;
    this.updateContextWindowCalculations();
  }

  // ---------------------------------------------------------------------------
  // Session Resume
  // ---------------------------------------------------------------------------

  /**
   * Restore state from previous session data.
   *
   * Used when resuming a session to restore token tracking state.
   *
   * @param data - Previous session data to restore
   */
  restoreState(data: { history: TokenRecord[]; accumulated?: AccumulatedTokens }): void {
    // Restore history
    this.state.history = data.history ?? [];

    // Restore current from last record
    const lastRecord = this.state.history[this.state.history.length - 1];
    this.state.current = lastRecord ?? null;

    // Restore accumulated or use defaults
    this.state.accumulated = data.accumulated ?? createEmptyAccumulatedTokens();

    // Restore context window from current record
    if (this.state.current) {
      this.state.contextWindow.currentSize = this.state.current.computed.contextWindowTokens;
    }
    this.updateContextWindowCalculations();

    logger.info('[TOKEN-RESTORE] State restored', {
      historyCount: this.state.history.length,
      contextWindow: this.state.contextWindow.currentSize,
      accumulatedInput: this.state.accumulated.inputTokens,
    });
  }

  // ---------------------------------------------------------------------------
  // Private Helpers
  // ---------------------------------------------------------------------------

  /**
   * Update derived context window calculations.
   */
  private updateContextWindowCalculations(): void {
    const { currentSize, maxSize } = this.state.contextWindow;

    // Calculate percentage (cap at 100)
    const rawPercent = maxSize > 0 ? (currentSize / maxSize) * 100 : 0;
    this.state.contextWindow.percentUsed = Math.min(100, rawPercent);

    // Calculate tokens remaining (floor at 0)
    this.state.contextWindow.tokensRemaining = Math.max(0, maxSize - currentSize);
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a new TokenStateManager instance.
 */
export function createTokenStateManager(config: TokenStateManagerConfig = {}): TokenStateManager {
  return new TokenStateManager(config);
}
