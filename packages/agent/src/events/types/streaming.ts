/**
 * @fileoverview Streaming Events
 *
 * Events for real-time streaming reconstruction.
 */

import type { BaseEvent } from './base.js';
import type { TokenUsage } from './token-usage.js';

// =============================================================================
// Normalized Token Usage
// =============================================================================

/**
 * Normalized token usage with semantic clarity for different UI components.
 * Handles the semantic differences in how different providers report tokens:
 * - Anthropic: inputTokens is NEW tokens only (excludes cache)
 * - OpenAI/Codex/Gemini: inputTokens is FULL context sent
 */
export interface NormalizedTokenUsage {
  /** Per-turn NEW input tokens (for stats line display) */
  newInputTokens: number;
  /** Output tokens for this turn */
  outputTokens: number;
  /** Total context window size (for progress pill) */
  contextWindowTokens: number;
  /** Raw input tokens as reported by provider (for billing/debugging) */
  rawInputTokens: number;
  /** Tokens read from cache (Anthropic/OpenAI) */
  cacheReadTokens: number;
  /** Tokens written to cache (Anthropic only) */
  cacheCreationTokens: number;
}

// =============================================================================
// Streaming Events
// =============================================================================

/**
 * Turn start event
 */
export interface StreamTurnStartEvent extends BaseEvent {
  type: 'stream.turn_start';
  payload: {
    turn: number;
  };
}

/**
 * Turn end event
 */
export interface StreamTurnEndEvent extends BaseEvent {
  type: 'stream.turn_end';
  payload: {
    turn: number;
    tokenUsage: TokenUsage;
    /**
     * Normalized token usage with semantic clarity for different UI components.
     * Handles provider semantic differences (Anthropic vs OpenAI/Codex/Gemini).
     */
    normalizedUsage?: NormalizedTokenUsage;
    /** Cost for this turn in USD */
    cost?: number;
  };
}

/**
 * Text delta for streaming reconstruction
 */
export interface StreamTextDeltaEvent extends BaseEvent {
  type: 'stream.text_delta';
  payload: {
    delta: string;
    turn: number;
    /** Content block index */
    blockIndex?: number;
  };
}

/**
 * Thinking delta for streaming reconstruction
 */
export interface StreamThinkingDeltaEvent extends BaseEvent {
  type: 'stream.thinking_delta';
  payload: {
    delta: string;
    turn: number;
  };
}
