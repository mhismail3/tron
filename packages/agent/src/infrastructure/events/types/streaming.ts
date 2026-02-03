/**
 * @fileoverview Streaming Events
 *
 * Events for real-time streaming reconstruction.
 */

import type { BaseEvent } from './base.js';
import type { TokenUsage } from './token-usage.js';
import type { TokenRecord } from '../../tokens/index.js';

// Re-export TokenRecord for convenience
export type { TokenRecord };

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
     * Token record with source (raw provider values), computed (normalized), and metadata.
     * The canonical token data structure from @infrastructure/tokens.
     */
    tokenRecord?: TokenRecord;
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
