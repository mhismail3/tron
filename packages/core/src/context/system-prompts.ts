/**
 * @fileoverview System Prompt Definitions
 *
 * Centralized system prompts for Tron agents. These are the Tron-specific
 * prompts that instruct the model on available tools and behaviors.
 *
 * Provider canonical prompts (OAuth prefix, Codex instructions) are handled
 * separately by each provider and CANNOT be modified.
 */

import type { ProviderType } from '../providers/index.js';

// =============================================================================
// Tron Core System Prompt
// =============================================================================

/**
 * Core Tron system prompt defining the assistant's role and capabilities.
 * This is provider-agnostic and gets adapted for each provider.
 */
export const TRON_CORE_PROMPT = `You are Tron, an AI coding assistant with full access to the user's file system.

You have access to the following tools:
- read: Read files from the file system
- write: Write content to files
- edit: Make targeted edits to existing files
- bash: Execute shell commands
- grep: Search for patterns in files
- find: Find files by name or pattern
- ls: List directory contents

When the user asks you to work with files or code, you can directly read, write, and edit files using these tools. You are operating on the server machine with full file system access.

Be helpful, accurate, and efficient. When working with code:
1. Read existing files to understand context before making changes
2. Make targeted, minimal edits rather than rewriting entire files
3. Test changes by running appropriate commands when asked
4. Explain what you're doing and why`;

/**
 * Working directory template - append to system prompt
 */
export const WORKING_DIRECTORY_SUFFIX = '\n\nCurrent working directory: {workingDirectory}';

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
