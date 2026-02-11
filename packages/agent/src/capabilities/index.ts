/**
 * @fileoverview Capabilities module exports
 *
 * The capabilities module provides agent capabilities including:
 * - Tools (bash, file operations, web, etc.)
 * - Extensions (hooks, skills, commands)
 * - Guardrails (safety checks)
 * - Tasks (persistent task management)
 */

export * from './tools/index.js';
export * from './extensions/hooks/index.js';
export * from './extensions/skills/index.js';
export * from './extensions/commands/index.js';
export * from './guardrails/index.js';
// Task management: use @capabilities/tasks/index.js directly
// Not re-exported to avoid Task type conflict with platform/productivity
