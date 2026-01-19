/**
 * @fileoverview System Prompt Definitions
 *
 * Centralized system prompts for Tron agents. These are the Tron-specific
 * prompts that instruct the model on available tools and behaviors.
 *
 * Provider canonical prompts (OAuth prefix, Codex instructions) are handled
 * separately by each provider and CANNOT be modified.
 */

import * as fs from 'fs';
import * as path from 'path';
import type { ProviderType } from '../providers/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('context:system-prompts');

// =============================================================================
// Tron Core System Prompt
// =============================================================================

/**
 * Core Tron system prompt defining the assistant's role and capabilities.
 * This is provider-agnostic and gets adapted for each provider.
 *
 * NOTE: This is a minimal FALLBACK prompt. The authoritative tool documentation
 * comes from each tool's schema (name, description, parameters) which is passed
 * directly to the model.
 *
 * Users should customize their system prompt by creating:
 *   - ~/.tron/rules/SYSTEM.md (global)
 *   - .tron/SYSTEM.md (project-level, takes precedence)
 *
 * See loadSystemPromptFromFileSync() for the loading logic.
 */
export const TRON_CORE_PROMPT = `You are Tron, an AI coding assistant with full access to the user's file system.

When the user asks you to work with files or code, you can directly read, write, and edit files using the available tools. You are operating on the server machine with full file system access.

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
  /** Source of the prompt (global or project) */
  source: 'global' | 'project';
}

/**
 * Load system prompt from filesystem hierarchy (synchronous).
 *
 * Priority order:
 * 1. Project: .tron/SYSTEM.md in working directory
 * 2. Global: ~/.tron/rules/SYSTEM.md (or system.md)
 *
 * Returns null if no files exist or if errors occur.
 *
 * @param options - Configuration for file loading
 * @returns Loaded prompt with source, or null if not found
 */
export function loadSystemPromptFromFileSync(options: {
  workingDirectory: string;
  userHome?: string;
}): LoadedSystemPrompt | null {
  const userHome = options.userHome ?? process.env.HOME ?? '';

  // 1. Try project-level SYSTEM.md first (.tron/SYSTEM.md)
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
    } else {
      const content = fs.readFileSync(projectPath, 'utf-8');
      logger.debug('Loaded system prompt from project', { path: projectPath });
      return { content, source: 'project' };
    }
  } catch (err) {
    // File doesn't exist or is unreadable - continue to global
  }

  // 2. Try global SYSTEM.md (~/.tron/rules/SYSTEM.md or system.md)
  if (userHome) {
    // Try both uppercase and lowercase variants
    const globalPaths = [
      path.join(userHome, '.tron', 'rules', 'SYSTEM.md'),
      path.join(userHome, '.tron', 'rules', 'system.md'),
    ];

    for (const globalPath of globalPaths) {
      try {
        const stats = fs.statSync(globalPath);

        // Check file size limit
        if (stats.size > MAX_SYSTEM_PROMPT_FILE_SIZE) {
          logger.warn('Global system prompt exceeds size limit', {
            path: globalPath,
            size: stats.size,
            limit: MAX_SYSTEM_PROMPT_FILE_SIZE,
          });
          continue;
        }

        const content = fs.readFileSync(globalPath, 'utf-8');
        logger.debug('Loaded system prompt from global', { path: globalPath });
        return { content, source: 'global' };
      } catch {
        // File doesn't exist or is unreadable, try next
      }
    }
  }

  // No files found
  return null;
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
