/**
 * @fileoverview System Prompt Definitions
 *
 * Centralized system prompts for Tron agents. These are the Tron-specific
 * prompts that instruct the model on available tools and behaviors.
 *
 * Provider canonical prompts (OAuth prefix, Codex instructions) are handled
 * separately by each provider and CANNOT be modified.
 *
 * Default prompt is loaded from ./system-prompts/core.md at module init.
 * Users can override by creating .tron/SYSTEM.md in their project directory.
 */

import * as fs from 'fs';
import * as path from 'path';
import type { ProviderType } from '@llm/providers/index.js';
import { createLogger } from '@infrastructure/logging/index.js';

// Re-export prompts from the system-prompts directory
export { TRON_CORE_PROMPT, WORKING_DIRECTORY_SUFFIX } from './system-prompts/index.js';
export { WEB_CONTENT_SUMMARIZER_PROMPT } from './system-prompts/index.js';
export { MEMORY_LEDGER_PROMPT } from './system-prompts/index.js';
export { COMPACTION_SUMMARIZER_PROMPT } from './system-prompts/index.js';

// Import for local use in this file
import { TRON_CORE_PROMPT, WORKING_DIRECTORY_SUFFIX } from './system-prompts/index.js';

const logger = createLogger('context:system-prompts');

// =============================================================================
// File-Based System Prompt Loading
// =============================================================================

/** Maximum file size for SYSTEM.md (100KB = ~25,000 tokens) */
const MAX_SYSTEM_PROMPT_FILE_SIZE = 100 * 1024;

/**
 * Result of loading a system prompt from file
 */
export interface LoadedSystemPrompt {
  /** File content */
  content: string;
  /** Source of the prompt */
  source: 'project';
}

/**
 * Load system prompt from project directory (synchronous).
 *
 * Looks for .tron/SYSTEM.md in the working directory.
 * If not found, returns null and the caller should use TRON_CORE_PROMPT.
 *
 * @param options - Configuration for file loading
 * @returns Loaded prompt with source, or null if not found
 */
export function loadSystemPromptFromFileSync(options: {
  workingDirectory: string;
}): LoadedSystemPrompt | null {
  // Try project-level SYSTEM.md (.tron/SYSTEM.md)
  const projectPath = path.join(options.workingDirectory, '.tron', 'SYSTEM.md');
  try {
    const stats = fs.statSync(projectPath);

    // Check file size limit
    if (stats.size > MAX_SYSTEM_PROMPT_FILE_SIZE) {
      logger.warn('Project SYSTEM.md exceeds size limit', {
        path: projectPath,
        size: stats.size,
        limit: MAX_SYSTEM_PROMPT_FILE_SIZE,
      });
      return null;
    }

    const content = fs.readFileSync(projectPath, 'utf-8');
    logger.debug('Loaded system prompt from project', { path: projectPath });
    return { content, source: 'project' };
  } catch {
    // File doesn't exist or is unreadable
    return null;
  }
}

// =============================================================================
// Provider-Specific System Prompt Builders
// =============================================================================

export interface SystemPromptConfig {
  /** Provider type */
  providerType: ProviderType;
  /** Working directory path */
  workingDirectory: string;
  /** Custom system prompt override (optional) */
  customPrompt?: string;
}

/**
 * Build the system prompt for Anthropic models.
 *
 * For Anthropic, the OAuth prefix is handled by the provider itself.
 * We just provide the Tron-specific content.
 */
export function buildAnthropicSystemPrompt(config: SystemPromptConfig): string {
  const basePrompt = config.customPrompt ?? TRON_CORE_PROMPT;
  return basePrompt + WORKING_DIRECTORY_SUFFIX.replace('{workingDirectory}', config.workingDirectory);
}

/**
 * Build the system prompt for OpenAI models.
 *
 * For standard OpenAI (gpt-4o, etc.), we provide the full system prompt.
 */
export function buildOpenAISystemPrompt(config: SystemPromptConfig): string {
  const basePrompt = config.customPrompt ?? TRON_CORE_PROMPT;
  return basePrompt + WORKING_DIRECTORY_SUFFIX.replace('{workingDirectory}', config.workingDirectory);
}

/**
 * Build Tron context for OpenAI Codex models.
 *
 * For OpenAI Codex, the system instructions are FIXED and cannot be modified
 * (ChatGPT OAuth validates them exactly). Instead, we inject Tron-specific
 * context via a tool clarification message at the start of the conversation.
 *
 * This is NOT a system prompt - it's content to be prepended to conversation.
 */
export function buildCodexToolClarification(config: SystemPromptConfig): string {
  const basePrompt = config.customPrompt ?? TRON_CORE_PROMPT;

  return `[TRON CONTEXT]
${basePrompt}

Current working directory: ${config.workingDirectory}

NOTE: The tools mentioned in the system instructions (shell, apply_patch, etc.) are NOT available.
Use ONLY the tools listed above (read, write, edit, bash, grep, find, ls).`;
}

/**
 * Build the system prompt for Google models.
 */
export function buildGoogleSystemPrompt(config: SystemPromptConfig): string {
  const basePrompt = config.customPrompt ?? TRON_CORE_PROMPT;
  return basePrompt + WORKING_DIRECTORY_SUFFIX.replace('{workingDirectory}', config.workingDirectory);
}

// =============================================================================
// Unified Builder
// =============================================================================

/**
 * Build a system prompt appropriate for the given provider.
 *
 * For most providers, this returns a system prompt string.
 * For OpenAI Codex, this returns context to prepend to conversation
 * (since Codex instructions cannot be modified).
 */
export function buildSystemPrompt(config: SystemPromptConfig): string {
  switch (config.providerType) {
    case 'anthropic':
      return buildAnthropicSystemPrompt(config);
    case 'openai':
      return buildOpenAISystemPrompt(config);
    case 'openai-codex':
      // For Codex, return an empty string for the actual system prompt
      // The Tron context is injected via tool clarification message
      return '';
    case 'google':
      return buildGoogleSystemPrompt(config);
    default:
      return buildAnthropicSystemPrompt(config);
  }
}

/**
 * Check if a provider requires a tool clarification message
 * instead of a custom system prompt.
 */
export function requiresToolClarificationMessage(providerType: ProviderType): boolean {
  return providerType === 'openai-codex';
}

/**
 * Get the tool clarification message for providers that need it.
 * Returns null if the provider uses standard system prompts.
 */
export function getToolClarificationMessage(config: SystemPromptConfig): string | null {
  if (config.providerType === 'openai-codex') {
    return buildCodexToolClarification(config);
  }
  return null;
}
