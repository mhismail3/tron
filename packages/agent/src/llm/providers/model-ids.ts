/**
 * @fileoverview Centralized Model ID Constants
 *
 * Single source of truth for model ID strings used throughout the codebase.
 * All model IDs correspond to keys in the provider model registries
 * (CLAUDE_MODELS, OPENAI_MODELS, GEMINI_MODELS).
 *
 * Usage:
 *   import { CLAUDE_HAIKU_4_5, SUBAGENT_MODEL } from '@llm/providers/model-ids.js';
 *
 * When adding a new model:
 * 1. Add it to the provider registry (anthropic/types.ts, openai/types.ts, etc.)
 * 2. Add a named constant here
 * 3. Update role aliases if the new model replaces one in a role
 */

// =============================================================================
// Anthropic Claude Model IDs
// =============================================================================

/** Claude Opus 4.6 — latest, most capable */
export const CLAUDE_OPUS_4_6 = 'claude-opus-4-6';

/** Claude Opus 4.5 */
export const CLAUDE_OPUS_4_5 = 'claude-opus-4-5-20251101';

/** Claude Sonnet 4.5 */
export const CLAUDE_SONNET_4_5 = 'claude-sonnet-4-5-20250929';

/** Claude Haiku 4.5 — fast, cheap */
export const CLAUDE_HAIKU_4_5 = 'claude-haiku-4-5-20251001';

/** Claude Opus 4.1 (legacy) */
export const CLAUDE_OPUS_4_1 = 'claude-opus-4-1-20250805';

/** Claude Opus 4 (legacy) */
export const CLAUDE_OPUS_4 = 'claude-opus-4-20250514';

/** Claude Sonnet 4 */
export const CLAUDE_SONNET_4 = 'claude-sonnet-4-20250514';

/** Claude 3.7 Sonnet (legacy) */
export const CLAUDE_3_7_SONNET = 'claude-3-7-sonnet-20250219';

/** Claude 3 Haiku (legacy) */
export const CLAUDE_3_HAIKU = 'claude-3-haiku-20240307';

// =============================================================================
// OpenAI Model IDs
// =============================================================================

/** GPT-5.3 Codex — latest */
export const GPT_5_3_CODEX = 'gpt-5.3-codex';

/** GPT-5.2 Codex */
export const GPT_5_2_CODEX = 'gpt-5.2-codex';

// =============================================================================
// Google Gemini Model IDs
// =============================================================================

/** Gemini 3 Pro (preview) */
export const GEMINI_3_PRO_PREVIEW = 'gemini-3-pro-preview';

/** Gemini 3 Flash (preview) */
export const GEMINI_3_FLASH_PREVIEW = 'gemini-3-flash-preview';

/** Gemini 2.5 Pro */
export const GEMINI_2_5_PRO = 'gemini-2.5-pro';

/** Gemini 2.5 Flash */
export const GEMINI_2_5_FLASH = 'gemini-2.5-flash';

/** Gemini 2.5 Flash Lite */
export const GEMINI_2_5_FLASH_LITE = 'gemini-2.5-flash-lite';

// =============================================================================
// Role-Based Aliases
//
// These define which model fills a particular role in the system.
// When upgrading models, change these aliases — consumers stay unchanged.
// =============================================================================

/** Model for subagent tasks (summarizer, ledger writer) — fast and cheap */
export const SUBAGENT_MODEL = CLAUDE_HAIKU_4_5;

/** Default model for API interactions */
export const DEFAULT_API_MODEL = CLAUDE_OPUS_4_6;

/** Default model for new server sessions */
export const DEFAULT_SERVER_MODEL = CLAUDE_SONNET_4;

/** Default Google model */
export const DEFAULT_GOOGLE_MODEL = GEMINI_2_5_FLASH;
