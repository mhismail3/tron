/**
 * @fileoverview Context Composition Utility
 *
 * Composes context fields from the Context interface into an ordered array
 * of text parts. Each provider decides how to use these parts:
 * - Anthropic: separate system prompt blocks (with cache_control on last)
 * - Google: separate systemInstruction parts
 * - OpenAI: joined into a single developer message
 *
 * The ordering is canonical and intentional:
 * 1. System prompt (core identity + behavior)
 * 2. Rules content (project-level rules from AGENTS.md / CLAUDE.md)
 * 3. Memory content (workspace lessons + cross-project recall)
 * 4. Dynamic rules (path-scoped .claude/rules/ files, changes as agent touches files)
 * 5. Skill context (ephemeral, changes per-skill invocation)
 * 6. Subagent results (completed sub-agent task results)
 * 7. Task context (current task list, updated per-turn)
 */

import type { Context } from '@core/types/index.js';

/**
 * Compose context fields into an ordered array of text parts.
 *
 * Returns an empty array if no context fields are present.
 * Each non-empty field is wrapped with its appropriate heading/tags.
 */
export function composeContextParts(context: Context): string[] {
  const parts: string[] = [];

  if (context.systemPrompt) {
    parts.push(context.systemPrompt);
  }

  if (context.rulesContent) {
    parts.push(`# Project Rules\n\n${context.rulesContent}`);
  }

  if (context.memoryContent) {
    parts.push(context.memoryContent);
  }

  if (context.dynamicRulesContext) {
    parts.push(`# Active Rules\n\n${context.dynamicRulesContext}`);
  }

  if (context.skillContext) {
    parts.push(context.skillContext);
  }

  if (context.subagentResultsContext) {
    parts.push(context.subagentResultsContext);
  }

  if (context.taskContext) {
    parts.push(`<task-context>\n${context.taskContext}\n</task-context>`);
  }

  return parts;
}
