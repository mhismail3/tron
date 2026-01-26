/**
 * @fileoverview Message Events
 *
 * Events for user, assistant, and system messages.
 */

import type { BaseEvent } from './base.js';
import type { TokenUsage } from './token-usage.js';
import type { NormalizedTokenUsage } from './streaming.js';

// =============================================================================
// Content Block Types
// =============================================================================

/** Content block types for messages */
export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: { type: 'base64'; mediaType: string; data: string } }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; toolUseId: string; content: string; isError?: boolean }
  | { type: 'thinking'; thinking: string };

// =============================================================================
// Message Events
// =============================================================================

/**
 * User message event
 */
export interface UserMessageEvent extends BaseEvent {
  type: 'message.user';
  payload: {
    content: string | ContentBlock[];
    /** Turn number within session */
    turn: number;
    /** Optional attached images */
    imageCount?: number;
  };
}

/**
 * Assistant message event
 */
export interface AssistantMessageEvent extends BaseEvent {
  type: 'message.assistant';
  payload: {
    content: ContentBlock[];
    turn: number;
    tokenUsage: TokenUsage;
    /**
     * Normalized token usage with semantic clarity for different UI components.
     * Handles provider semantic differences (Anthropic vs OpenAI/Codex/Gemini).
     * This is stored directly on message.assistant so iOS can reconstruct without
     * correlating with stream.turn_end events.
     */
    normalizedUsage?: NormalizedTokenUsage;
    stopReason: 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence';
    /** Duration of LLM call in ms */
    latency?: number;
    /** Model used (may differ from session default) */
    model: string;
    /** Whether extended thinking was used */
    hasThinking?: boolean;
  };
}

/**
 * System message event
 */
export interface SystemMessageEvent extends BaseEvent {
  type: 'message.system';
  payload: {
    content: string;
    source: 'compaction' | 'context' | 'hook' | 'error' | 'inject';
  };
}
