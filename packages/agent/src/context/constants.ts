/**
 * @fileoverview Context Subsystem Constants
 *
 * Shared constants for LLM summarizer, context manager,
 * system prompts, and token estimator.
 */

// =============================================================================
// LLM Summarizer
// =============================================================================

export const SUMMARIZER_MAX_SERIALIZED_CHARS = 150_000;
export const SUMMARIZER_ASSISTANT_TEXT_LIMIT = 300;
export const SUMMARIZER_THINKING_TEXT_LIMIT = 500;
export const SUMMARIZER_TOOL_RESULT_TEXT_LIMIT = 100;
export const SUMMARIZER_SUBAGENT_TIMEOUT_MS = 30_000;

// =============================================================================
// Context Manager — tool result budgeting
// =============================================================================

export const TOOL_RESULT_MIN_TOKENS = 2_500;
export const TOOL_RESULT_MAX_CHARS = 100_000;

// =============================================================================
// System Prompts
// =============================================================================

export const MAX_SYSTEM_PROMPT_FILE_SIZE = 100 * 1024;

// =============================================================================
// Token Estimation
// =============================================================================

export const CHARS_PER_TOKEN = 4;
export const MIN_IMAGE_TOKENS = 85;
export const DEFAULT_URL_IMAGE_TOKENS = 1500;
