/**
 * @fileoverview Stop Reason Mapping Utilities
 *
 * Maps provider-specific stop reasons to the unified Tron format.
 * Each provider uses different terminology for why the model stopped generating.
 *
 * Unified format (StopReason):
 * - 'end_turn': Normal completion
 * - 'max_tokens': Hit token limit
 * - 'tool_use': Model wants to use a tool
 * - 'stop_sequence': Hit a stop sequence
 */

import type { StopReason } from '@core/types/messages.js';

// Re-export for convenience
export type { StopReason };

/**
 * Map OpenAI stop reason to unified format.
 *
 * OpenAI values: 'stop', 'length', 'tool_calls', 'content_filter', null
 */
export function mapOpenAIStopReason(reason: string | null): StopReason {
  switch (reason) {
    case 'stop':
      return 'end_turn';
    case 'length':
      return 'max_tokens';
    case 'tool_calls':
      return 'tool_use';
    case 'content_filter':
      return 'end_turn';
    default:
      return 'end_turn';
  }
}

/**
 * Map Google/Gemini stop reason to unified format.
 *
 * Google values: 'STOP', 'MAX_TOKENS', 'SAFETY', 'RECITATION', 'OTHER'
 */
export function mapGoogleStopReason(reason: string): StopReason {
  switch (reason) {
    case 'STOP':
      return 'end_turn';
    case 'MAX_TOKENS':
      return 'max_tokens';
    case 'SAFETY':
      return 'end_turn';
    case 'RECITATION':
      return 'end_turn';
    case 'OTHER':
      return 'end_turn';
    default:
      return 'end_turn';
  }
}
