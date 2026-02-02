/**
 * @fileoverview Skill to Denials Converter
 *
 * Converts skill frontmatter's allowedTools to ToolDenialConfig for subagent execution.
 * This enables skills to specify what tools they need (positive permissions),
 * which get converted to denials (everything else blocked) when running in subagent mode.
 *
 * Design principles:
 * - Skills define what they NEED (positive permissions)
 * - Subagents enforce restrictions (everything not allowed is denied)
 * - Reuses existing ToolDenialConfig infrastructure
 */

import type { ToolDenialConfig, ToolDenialRule, ParameterDenialPattern } from '../../tools/subagent/tool-denial.js';
import type { SkillFrontmatter, AllowedPatternRule } from './types.js';

/**
 * Convert a skill's allowedTools to a ToolDenialConfig.
 *
 * This is used when spawning a subagent with `subagent: 'yes'` to enforce
 * tool restrictions. The skill specifies what it needs (positive permissions),
 * and this function computes the inverse (what to deny).
 *
 * @param frontmatter - Skill frontmatter with allowedTools/allowedPatterns
 * @param allAvailableTools - List of all available tool names
 * @returns ToolDenialConfig or undefined if no restrictions
 *
 * @example
 * // Skill allows Read and Glob
 * const denials = skillAllowedToolsToDenials(
 *   { allowedTools: ['Read', 'Glob'] },
 *   ['Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash']
 * );
 * // Result: { tools: ['Write', 'Edit', 'Grep', 'Bash'] }
 */
export function skillAllowedToolsToDenials(
  frontmatter: SkillFrontmatter,
  allAvailableTools: string[]
): ToolDenialConfig | undefined {
  const allowedTools = frontmatter.allowedTools;

  // No restrictions if no allowedTools specified
  if (!allowedTools || allowedTools.length === 0) {
    return undefined;
  }

  // Compute denied tools = all tools - allowed tools
  const allowedSet = new Set(allowedTools);
  const deniedTools = allAvailableTools.filter(t => !allowedSet.has(t));

  // Convert allowedPatterns to denyPatterns (invert the logic)
  const rules: ToolDenialRule[] = [];

  if (frontmatter.allowedPatterns && frontmatter.allowedPatterns.length > 0) {
    for (const allowRule of frontmatter.allowedPatterns) {
      const denyPatterns = convertAllowedPatternsToDenyPatterns(allowRule);
      if (denyPatterns.length > 0) {
        rules.push({
          tool: allowRule.tool,
          denyPatterns,
          message: `Only specific ${allowRule.tool} invocations allowed by skill`,
        });
      }
    }
  }

  // Return undefined if no denials
  if (deniedTools.length === 0 && rules.length === 0) {
    return undefined;
  }

  return {
    tools: deniedTools.length > 0 ? deniedTools : undefined,
    rules: rules.length > 0 ? rules : undefined,
  };
}

/**
 * Convert allowed pattern rules to deny pattern rules.
 *
 * For each parameter with allowed patterns, we create a deny pattern
 * that matches everything EXCEPT the allowed patterns.
 *
 * @param allowRule - The allowed pattern rule from skill frontmatter
 * @returns Array of parameter denial patterns
 */
function convertAllowedPatternsToDenyPatterns(
  allowRule: AllowedPatternRule
): ParameterDenialPattern[] {
  const denyPatterns: ParameterDenialPattern[] = [];

  for (const constraint of allowRule.patterns) {
    // Create a negative lookahead pattern that denies everything except allowed
    // This is a simplified approach - for complex patterns, you might need
    // a more sophisticated regex engine
    const allowedPatterns = constraint.allow;

    if (allowedPatterns.length === 0) {
      continue;
    }

    // Build a regex that matches anything NOT matching the allowed patterns
    // Using negative lookahead: ^(?!pattern1|pattern2).*$
    // Note: This works for simple patterns but may need refinement for complex ones
    const combinedAllowed = allowedPatterns
      .map(p => `(${p})`)
      .join('|');

    denyPatterns.push({
      parameter: constraint.parameter,
      // Deny anything that doesn't match any of the allowed patterns
      patterns: [`^(?!.*(?:${combinedAllowed})).*$`],
    });
  }

  return denyPatterns;
}

/**
 * Get effective allowed tools for a skill.
 *
 * @param frontmatter - Skill frontmatter
 * @returns Array of allowed tool names, or undefined if no restrictions
 */
export function getEffectiveAllowedTools(
  frontmatter: SkillFrontmatter
): string[] | undefined {
  if (frontmatter.allowedTools && frontmatter.allowedTools.length > 0) {
    return frontmatter.allowedTools;
  }

  return undefined;
}

/**
 * Check if a skill should spawn a subagent.
 *
 * @param frontmatter - Skill frontmatter
 * @returns The subagent mode, defaulting to 'no'
 */
export function getSkillSubagentMode(
  frontmatter: SkillFrontmatter
): 'no' | 'ask' | 'yes' {
  return frontmatter.subagent ?? 'no';
}
