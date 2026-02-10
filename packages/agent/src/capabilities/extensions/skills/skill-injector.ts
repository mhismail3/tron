/**
 * @fileoverview Skill Injector
 *
 * Extracts @skill-name references from user prompts and builds
 * the <skills>...</skills> XML context block for injection.
 */

import type { SkillMetadata, SkillReference, SkillInjectionResult } from './types.js';
import type { SkillRegistry } from './skill-registry.js';

// =============================================================================
// Reference Extraction
// =============================================================================

/**
 * Regex to match @skill-name references.
 * Matches:
 * - @skillname (alphanumeric)
 * - @skill-name (with hyphens)
 * - @skill_name (with underscores)
 *
 * Does NOT match:
 * - @user in email addresses
 * - Inside code blocks or backticks
 */
const SKILL_REFERENCE_REGEX = /(?<!\`|\w)@([a-zA-Z][a-zA-Z0-9_-]*)/g;

/**
 * Extract @skill-name references from a prompt
 */
export function extractSkillReferences(prompt: string): SkillReference[] {
  const references: SkillReference[] = [];

  // Simple code block detection - track if we're inside a code block
  // This is a heuristic - triple backticks toggle code block state
  const lines = prompt.split('\n');
  let inCodeBlock = false;
  let currentPosition = 0;

  for (const line of lines) {
    // Check for code block toggle
    if (line.trim().startsWith('```')) {
      inCodeBlock = !inCodeBlock;
    }

    // Only extract references outside code blocks
    if (!inCodeBlock) {
      // Use matchAll to get all matches with their indices
      const lineMatches = [...line.matchAll(SKILL_REFERENCE_REGEX)];
      for (const match of lineMatches) {
        if (match.index === undefined) continue;

        // Check if this @reference is inside inline code (`...`)
        const beforeMatch = line.slice(0, match.index);
        const backtickCount = (beforeMatch.match(/`/g) || []).length;
        if (backtickCount % 2 !== 0) {
          // Inside inline code, skip
          continue;
        }

        const extractedName = match[1];
        if (!extractedName) continue;

        references.push({
          original: match[0],
          name: extractedName,
          position: {
            start: currentPosition + match.index,
            end: currentPosition + match.index + match[0].length,
          },
        });
      }
    }

    // Add line length + newline to current position
    currentPosition += line.length + 1;
  }

  return references;
}

/**
 * Remove @skill-name references from a prompt, leaving the rest intact
 */
export function removeSkillReferences(prompt: string, references: SkillReference[]): string {
  // Sort references by position (descending) to remove from end first
  // This preserves the positions of earlier references
  const sorted = [...references].sort((a, b) => b.position.start - a.position.start);

  let result = prompt;
  for (const ref of sorted) {
    // Remove the reference
    const before = result.slice(0, ref.position.start);
    const after = result.slice(ref.position.end);
    result = before + after;
  }

  // Clean up multiple spaces and trim
  return result.replace(/  +/g, ' ').trim();
}

// =============================================================================
// Context Generation
// =============================================================================

/**
 * Build a tool preferences/restrictions block for skills that specify tool constraints.
 */
function buildToolPreferences(skill: SkillMetadata): string {
  const fm = skill.frontmatter;

  if (fm.allowedTools && fm.allowedTools.length > 0) {
    return `<skill-tool-preferences>This skill works best with: ${fm.allowedTools.join(', ')}. Prefer these tools.</skill-tool-preferences>`;
  }

  if (fm.deniedTools && fm.deniedTools.length > 0) {
    return `<skill-tool-restrictions>This skill must NOT use: ${fm.deniedTools.join(', ')}. These tools are restricted.</skill-tool-restrictions>`;
  }

  return '';
}

/**
 * Build the <skills> XML block from a list of skills
 */
export function buildSkillContext(skills: SkillMetadata[]): string {
  if (skills.length === 0) return '';

  const parts: string[] = ['<skills>'];

  for (const skill of skills) {
    parts.push(`<skill name="${escapeXml(skill.name)}">`);

    // Add tool preferences if this skill specifies allowedTools
    const toolPrefs = buildToolPreferences(skill);
    if (toolPrefs) {
      parts.push(toolPrefs);
      parts.push('');
    }

    parts.push(skill.content);
    parts.push('</skill>');
    parts.push('');
  }

  parts.push('</skills>');

  return parts.join('\n');
}

/**
 * Escape special XML characters
 */
function escapeXml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

// =============================================================================
// Main Injector
// =============================================================================

/**
 * Process a prompt for skill injection.
 * Extracts @references, looks up skills, and builds the injection result.
 */
export function processPromptForSkills(
  prompt: string,
  registry: SkillRegistry,
): SkillInjectionResult {
  const references = extractSkillReferences(prompt);
  const referencedNames = [...new Set(references.map(r => r.name))];
  const { found, notFound } = registry.getMany(referencedNames);

  const cleanedPrompt = removeSkillReferences(prompt, references);
  const skillContext = buildSkillContext(found);

  return {
    originalPrompt: prompt,
    cleanedPrompt,
    injectedSkills: found,
    notFoundSkills: notFound,
    skillContext,
  };
}

/**
 * Build the full message content with skill context prepended
 */
export function buildMessageWithSkillContext(
  prompt: string,
  skillContext: string
): string {
  if (!skillContext) return prompt;

  return `${skillContext}\n\n${prompt}`;
}
