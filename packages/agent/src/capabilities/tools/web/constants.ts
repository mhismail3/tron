/**
 * @fileoverview Web Tools Constants
 *
 * Shared constants for web fetch, content truncation, HTML parsing,
 * URL validation, summarizer, and search tools.
 *
 * Note: Provider-specific constants (Brave endpoint limits, Exa defaults)
 * remain in their respective type files (brave-types.ts, exa-types.ts).
 */

// =============================================================================
// WebFetch
// =============================================================================

export const WEB_FETCH_DEFAULT_TIMEOUT_MS = 30_000;
export const WEB_FETCH_USER_AGENT = 'TronAgent/1.0 (+https://github.com/tron-agent)';
export const WEB_FETCH_MAX_RESPONSE_SIZE = 10 * 1024 * 1024;
export { SUBAGENT_MODEL as WEB_FETCH_HAIKU_MODEL } from '@llm/providers/model-ids.js';
export const WEB_FETCH_MAX_SUMMARIZER_TURNS = 3;

// =============================================================================
// Content Truncator
// =============================================================================

export const TRUNCATOR_MAX_TOKENS = 50_000;
export const TRUNCATOR_PRESERVE_START_LINES = 100;

// =============================================================================
// HTML Parser
// =============================================================================

export const HTML_MAX_CONTENT_LENGTH = 500_000;

// =============================================================================
// URL Validator
// =============================================================================

export const URL_MAX_LENGTH = 2_000;

// =============================================================================
// Summarizer
// =============================================================================

export const SUMMARIZER_MAX_TOKENS = 1024;
export { SUBAGENT_MODEL as SUMMARIZER_HAIKU_MODEL } from '@llm/providers/model-ids.js';

// =============================================================================
// Search
// =============================================================================

export const SEARCH_MAX_QUERY_LENGTH = 400;
export const BRAVE_DEFAULT_TIMEOUT_MS = 15_000;
