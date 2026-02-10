/**
 * @fileoverview Skill Frontmatter to Denials Converter
 *
 * Converts skill frontmatter tool restrictions to ToolDenialConfig for subagent execution.
 * Supports two modes:
 * - Deny-list (primary): deniedTools specifies what to block
 * - Allow-list (secondary): allowedTools specifies what to permit (everything else blocked)
 */

import type { ToolDenialConfig } from '../../tools/subagent/tool-denial.js';
import type { SkillFrontmatter } from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('skill-to-denials');

/**
 * Convert skill frontmatter tool restrictions to a ToolDenialConfig.
 *
 * Deny-list mode (deniedTools): directly maps to denied tools.
 * Allow-list mode (allowedTools): computes denied = allAvailable - allowed.
 * If both are specified, deniedTools takes precedence with a warning.
 *
 * @param frontmatter - Skill frontmatter with deniedTools/allowedTools
 * @param allAvailableTools - List of all available tool names (for allow-list inversion)
 * @returns ToolDenialConfig or undefined if no restrictions
 */
export function skillFrontmatterToDenials(
  frontmatter: SkillFrontmatter,
  allAvailableTools: string[]
): ToolDenialConfig | undefined {
  const hasDenied = frontmatter.deniedTools && frontmatter.deniedTools.length > 0;
  const hasAllowed = frontmatter.allowedTools && frontmatter.allowedTools.length > 0;

  // Mutual exclusivity check
  if (hasDenied && hasAllowed) {
    logger.warn('Skill specifies both deniedTools and allowedTools; using deniedTools', {
      deniedTools: frontmatter.deniedTools,
      allowedTools: frontmatter.allowedTools,
    });
  }

  // Deny-list mode: deniedTools specified
  if (hasDenied) {
    return {
      tools: frontmatter.deniedTools,
      rules: frontmatter.deniedPatterns?.map(r => ({
        tool: r.tool,
        denyPatterns: r.denyPatterns,
        message: r.message,
      })),
    };
  }

  // Allow-list mode: allowedTools specified (compute inverse)
  if (hasAllowed) {
    const allowedSet = new Set(frontmatter.allowedTools);
    const denied = allAvailableTools.filter(t => !allowedSet.has(t));
    return denied.length > 0 ? { tools: denied } : undefined;
  }

  // No restrictions
  return undefined;
}

/**
 * Get the subagent execution mode for a skill.
 *
 * @param frontmatter - Skill frontmatter
 * @returns The subagent mode, defaulting to 'no'
 */
export function getSkillSubagentMode(
  frontmatter: SkillFrontmatter
): 'no' | 'ask' | 'yes' {
  return frontmatter.subagent ?? 'no';
}
