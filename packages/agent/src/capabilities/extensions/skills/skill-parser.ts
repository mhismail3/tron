/**
 * @fileoverview Skill Parser
 *
 * Parses SKILL.md files to extract YAML frontmatter, description,
 * and body content. Uses a simple YAML parser to avoid external dependencies.
 */

import type { SkillFrontmatter } from './types.js';

// =============================================================================
// Types
// =============================================================================

export interface ParsedSkillMd {
  /** Parsed frontmatter (empty object if none) */
  frontmatter: SkillFrontmatter;
  /** Content after frontmatter */
  content: string;
  /** First non-header, non-empty line (skill description) */
  description: string;
}

// =============================================================================
// Frontmatter Parsing
// =============================================================================

/**
 * Extract YAML frontmatter from markdown content.
 * Frontmatter is delimited by --- at the start and end.
 */
function extractFrontmatter(content: string): {
  yaml: string | null;
  body: string;
} {
  const trimmed = content.trim();

  // Check if content starts with ---
  if (!trimmed.startsWith('---')) {
    return { yaml: null, body: content };
  }

  // Find the closing ---
  const endIndex = trimmed.indexOf('\n---', 3);
  if (endIndex === -1) {
    // No closing --- found, treat entire content as body
    return { yaml: null, body: content };
  }

  const yaml = trimmed.slice(4, endIndex).trim();
  const body = trimmed.slice(endIndex + 4).trim();

  return { yaml, body };
}

/**
 * Simple YAML parser for skill frontmatter.
 * Supports basic key-value pairs, booleans, strings, and arrays.
 */
function parseSimpleYaml(yaml: string): SkillFrontmatter {
  const result: SkillFrontmatter = {};
  const lines = yaml.split('\n');

  let currentKey: string | null = null;
  let currentArray: string[] | null = null;

  for (const line of lines) {
    const trimmed = line.trim();

    // Skip empty lines and comments
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }

    // Check for array item (starts with -)
    if (trimmed.startsWith('- ') && currentKey && currentArray) {
      const value = trimmed.slice(2).trim();
      // Remove quotes if present
      const unquoted = value.replace(/^["']|["']$/g, '');
      currentArray.push(unquoted);
      continue;
    }

    // Check for key: value pair
    const colonIndex = trimmed.indexOf(':');
    if (colonIndex === -1) continue;

    const key = trimmed.slice(0, colonIndex).trim();
    const rawValue = trimmed.slice(colonIndex + 1).trim();

    // If value is empty, expect an array on following lines
    if (!rawValue) {
      currentKey = key;
      currentArray = [];
      if (key === 'tools') {
        result.tools = currentArray;
      } else if (key === 'tags') {
        result.tags = currentArray;
      }
      continue;
    }

    // Reset array tracking for non-array keys
    currentKey = null;
    currentArray = null;

    // Parse the value based on key
    const value = parseYamlValue(rawValue);

    switch (key) {
      case 'name':
        result.name = String(value);
        break;
      case 'description':
        result.description = String(value);
        break;
      case 'autoInject':
        result.autoInject = value === true || value === 'true';
        break;
      case 'version':
        result.version = String(value);
        break;
      case 'tools':
        // Inline array: tools: [read, write]
        if (typeof value === 'string' && value.startsWith('[')) {
          result.tools = parseInlineArray(value);
        }
        break;
      case 'tags':
        // Inline array: tags: [coding, standards]
        if (typeof value === 'string' && value.startsWith('[')) {
          result.tags = parseInlineArray(value);
        }
        break;
    }
  }

  return result;
}

/**
 * Parse a YAML value (boolean, number, or string)
 */
function parseYamlValue(value: string): string | boolean | number {
  const lower = value.toLowerCase();

  // Boolean
  if (lower === 'true') return true;
  if (lower === 'false') return false;

  // Number
  const num = Number(value);
  if (!isNaN(num) && value !== '') return num;

  // String (remove quotes if present)
  return value.replace(/^["']|["']$/g, '');
}

/**
 * Parse an inline YAML array: [item1, item2, item3]
 */
function parseInlineArray(value: string): string[] {
  // Remove brackets and split by comma
  const inner = value.slice(1, -1);
  return inner
    .split(',')
    .map(item => item.trim().replace(/^["']|["']$/g, ''))
    .filter(item => item.length > 0);
}

// =============================================================================
// Description Extraction
// =============================================================================

/**
 * Extract the first non-header, non-empty line as the description
 */
function extractDescription(content: string): string {
  const lines = content.split('\n');

  for (const line of lines) {
    const trimmed = line.trim();

    // Skip empty lines
    if (!trimmed) continue;

    // Skip markdown headers
    if (trimmed.startsWith('#')) continue;

    // Skip horizontal rules
    if (/^[-*_]{3,}$/.test(trimmed)) continue;

    // Skip code block markers
    if (trimmed.startsWith('```')) continue;

    // Found a content line - use it as description
    // Truncate to reasonable length
    return trimmed.slice(0, 200);
  }

  return '';
}

// =============================================================================
// Main Parser
// =============================================================================

/**
 * Parse a SKILL.md file content
 */
export function parseSkillMd(rawContent: string): ParsedSkillMd {
  const { yaml, body } = extractFrontmatter(rawContent);

  const frontmatter = yaml ? parseSimpleYaml(yaml) : {};
  const description = extractDescription(body);

  return {
    frontmatter,
    content: body,
    description,
  };
}
