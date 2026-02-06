/**
 * @fileoverview System Prompts Index
 *
 * Central export point for all system prompts used by Tron agents
 * and subagents.
 */

// Core agent prompt
export { TRON_CORE_PROMPT, WORKING_DIRECTORY_SUFFIX } from './core.js';

// Subagent prompts
export { WEB_CONTENT_SUMMARIZER_PROMPT } from './summarizer.js';
export { MEMORY_LEDGER_PROMPT } from './memory-ledger.js';
export { COMPACTION_SUMMARIZER_PROMPT } from './compaction-summarizer.js';
