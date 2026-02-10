/**
 * @fileoverview Runtime Subsystem Constants
 *
 * Shared constants for agent factory, spawn handler, and related modules.
 */

export const SUBAGENT_MAX_TOKENS_MULTIPLIER = 0.9;
export const DEFAULT_GUARDRAIL_TIMEOUT_MS = 60 * 60 * 1000;
export const TMUX_STARTUP_TIMEOUT_MS = 10_000;

/** Default maximum agentic turns before the agent loop stops */
export const MAX_TURNS_DEFAULT = 100;

/** Token buffer reserved for compaction overhead during pre-turn validation */
export const COMPACTION_BUFFER_TOKENS = 4_000;

/** Inactivity threshold (ms) before a session is eligible for cleanup */
export const INACTIVE_SESSION_TIMEOUT_MS = 30 * 60 * 1000;

/** Default length of random ID segments (hex characters from UUID) */
export const EVENT_ID_LENGTH = 12;

/** Default max output tokens when model info is unavailable */
export const DEFAULT_MAX_OUTPUT_TOKENS = 16_384;

/**
 * Tools excluded from subagent sessions to prevent infinite recursion
 * and limit subagent capabilities to focused task execution.
 */
export const SUBAGENT_EXCLUDED_TOOLS = [
  'SpawnSubagent',
  'QueryAgent',
  'WaitForAgents',
] as const;
