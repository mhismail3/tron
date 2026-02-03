/**
 * @fileoverview Token Module
 *
 * Unified module for token tracking throughout the system.
 *
 * ## Design Principles
 *
 * 1. **Provider API Response is the SOLE Source of Truth**
 *    All token values originate from provider API responses.
 *
 * 2. **Immutable TokenRecord**
 *    Complete audit trail with source, computed, and metadata.
 *    Once created, never mutated.
 *
 * 3. **Fail-Visible Design**
 *    Missing/zero tokens throw errors, not silent 0s.
 *
 * ## Usage
 *
 * ```typescript
 * import {
 *   TokenStateManager,
 *   extractFromAnthropic,
 *   extractFromOpenAI,
 *   extractFromGoogle,
 * } from '@infrastructure/tokens';
 *
 * // Create manager for a session
 * const manager = new TokenStateManager({ contextLimit: 200_000 });
 *
 * // Extract tokens from provider response
 * const source = extractFromAnthropic(messageStartUsage, messageDeltaUsage, { turn: 1, sessionId: 'sess_abc' });
 *
 * // Record the turn
 * const record = manager.recordTurn(source, { turn: 1, sessionId: 'sess_abc', extractedAt: '', normalizedAt: '' }, cost);
 *
 * // Access state
 * const state = manager.getState();
 * console.log(state.contextWindow.percentUsed);
 * ```
 */

// =============================================================================
// Types
// =============================================================================

export {
  // Core types
  type ProviderType,
  type TokenSource,
  type ComputedTokens,
  type CalculationMethod,
  type TokenMeta,
  type TokenRecord,
  type AccumulatedTokens,
  type ContextWindowState,
  type TokenState,
  // Error types
  TokenExtractionError,
  // Factory functions
  createEmptyTokenState,
  createEmptyAccumulatedTokens,
} from './types.js';

// =============================================================================
// Extraction
// =============================================================================

export {
  // Extractors
  extractFromAnthropic,
  extractFromOpenAI,
  extractFromGoogle,
  // Types
  type AnthropicMessageStartUsage,
  type AnthropicMessageDeltaUsage,
  type OpenAIUsage,
  type GoogleUsageMetadata,
  type ExtractionMeta,
} from './extraction/index.js';

// =============================================================================
// Normalization
// =============================================================================

export { normalizeTokens, detectProviderFromModel } from './normalization/index.js';

// =============================================================================
// State Management
// =============================================================================

export {
  TokenStateManager,
  createTokenStateManager,
  type TokenStateManagerConfig,
} from './state/token-state-manager.js';
