/**
 * @fileoverview Token Usage Types
 *
 * Types for tracking token consumption.
 */

// =============================================================================
// Token Usage
// =============================================================================

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}
