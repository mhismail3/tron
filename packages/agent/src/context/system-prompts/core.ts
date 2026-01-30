/**
 * @fileoverview Core Tron System Prompt
 *
 * The main system prompt for Tron agents defining the assistant's
 * role and capabilities. This is provider-agnostic.
 */

/**
 * Core Tron system prompt defining the assistant's role and capabilities.
 *
 * NOTE: This is a minimal FALLBACK prompt. The authoritative tool documentation
 * comes from each tool's schema (name, description, parameters) which is passed
 * directly to the model.
 *
 * Users should customize their system prompt by creating:
 *   - ~/.tron/rules/SYSTEM.md (global)
 *   - .tron/SYSTEM.md (project-level, takes precedence)
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
