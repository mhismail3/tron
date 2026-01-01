/**
 * @fileoverview Skill File Parser
 *
 * Parses SKILL.md files with YAML frontmatter.
 */
import type { ParsedSkillFile, SkillFrontmatter, Skill, SkillArgument } from './types.js';

// =============================================================================
// Frontmatter Parsing
// =============================================================================

const FRONTMATTER_REGEX = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/;

/**
 * Parse a skill file into frontmatter and body
 */
export function parseSkillFile(content: string): ParsedSkillFile {
  const match = content.match(FRONTMATTER_REGEX);

  if (!match) {
    // No frontmatter, treat entire content as body
    return {
      frontmatter: {
        name: 'Unnamed Skill',
        description: '',
      },
      body: content.trim(),
    };
  }

  const frontmatterYaml = match[1] ?? '';
  const body = (match[2] ?? '').trim();

  const frontmatter = parseYaml(frontmatterYaml);

  return { frontmatter, body };
}

/**
 * Simple YAML parser for frontmatter
 */
function parseYaml(yaml: string): SkillFrontmatter {
  const result: Record<string, unknown> = {};
  const lines = yaml.split('\n');
  let currentKey = '';
  let currentArray: unknown[] | null = null;
  let inArrayItem = false;
  let arrayItemContent: Record<string, unknown> = {};

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const trimmed = line.trim();

    if (!trimmed || trimmed.startsWith('#')) continue;

    // Array item (starts with -)
    if (trimmed.startsWith('- ')) {
      if (!currentArray) {
        currentArray = [];
      }

      // Push previous array item if any
      if (inArrayItem && Object.keys(arrayItemContent).length > 0) {
        currentArray.push(arrayItemContent);
        arrayItemContent = {};
      }

      const itemContent = trimmed.slice(2).trim();

      // Check if it's a simple value or object start
      if (itemContent.includes(':')) {
        // Object in array
        inArrayItem = true;
        arrayItemContent = {};
        const parts = itemContent.split(':').map(s => s.trim());
        const key = parts[0] ?? '';
        const value = parts[1];
        if (key && value) {
          arrayItemContent[key] = parseValue(value);
        }
      } else {
        // Simple value
        inArrayItem = false;
        currentArray.push(parseValue(itemContent));
      }
      continue;
    }

    // Continuation of array item object
    if (inArrayItem && /^\s{4,}\w+:/.test(line)) {
      const parts = trimmed.split(':');
      const key = (parts[0] ?? '').trim();
      const value = parts.slice(1).join(':').trim();
      if (key) {
        arrayItemContent[key] = parseValue(value);
      }
      continue;
    }

    // End of array item object
    if (inArrayItem && !/^\s+/.test(line) && trimmed.includes(':')) {
      if (currentArray && Object.keys(arrayItemContent).length > 0) {
        currentArray.push(arrayItemContent);
      }
      inArrayItem = false;
      arrayItemContent = {};
    }

    // Key-value pair
    const colonIndex = trimmed.indexOf(':');
    if (colonIndex !== -1) {
      // Save previous array if any
      if (currentKey && currentArray) {
        if (inArrayItem && Object.keys(arrayItemContent).length > 0) {
          currentArray.push(arrayItemContent);
        }
        result[currentKey] = currentArray;
        currentArray = null;
        inArrayItem = false;
        arrayItemContent = {};
      }

      const key = trimmed.slice(0, colonIndex).trim();
      const value = trimmed.slice(colonIndex + 1).trim();

      if (value) {
        result[key] = parseValue(value);
      } else {
        // Array or nested object follows
        currentKey = key;
        currentArray = [];
      }
    }
  }

  // Save final array if any
  if (currentKey && currentArray) {
    if (inArrayItem && Object.keys(arrayItemContent).length > 0) {
      currentArray.push(arrayItemContent);
    }
    result[currentKey] = currentArray;
  }

  // Ensure required fields have defaults
  if (!result.name) result.name = 'Unnamed Skill';
  if (!result.description) result.description = '';
  return result as unknown as SkillFrontmatter;
}

/**
 * Parse a YAML value
 */
function parseValue(value: string): unknown {
  // Remove quotes
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1);
  }

  // Boolean
  if (value === 'true') return true;
  if (value === 'false') return false;

  // Number
  const num = Number(value);
  if (!isNaN(num) && value !== '') return num;

  // String
  return value;
}

// =============================================================================
// Skill Building
// =============================================================================

/**
 * Build a Skill from parsed file content
 */
export function buildSkillFromParsed(
  parsed: ParsedSkillFile,
  filePath?: string
): Skill {
  const { frontmatter, body } = parsed;

  // Generate ID from name if not provided
  const id = frontmatter.command ||
    frontmatter.name.toLowerCase().replace(/\s+/g, '-');

  const skill: Skill = {
    id,
    name: frontmatter.name,
    description: frontmatter.description || '',
    command: frontmatter.command,
    version: frontmatter.version,
    author: frontmatter.author,
    tags: frontmatter.tags,
    arguments: frontmatter.arguments?.map(normalizeArgument),
    dependencies: frontmatter.dependencies,
    instructions: body,
    examples: frontmatter.examples,
    filePath,
    builtIn: false,
  };

  return skill;
}

/**
 * Normalize an argument definition
 */
function normalizeArgument(arg: SkillArgument | Record<string, unknown>): SkillArgument {
  if ('name' in arg && 'description' in arg) {
    return {
      name: String(arg.name),
      description: String(arg.description),
      type: (arg.type as SkillArgument['type']) || 'string',
      required: Boolean(arg.required),
      default: arg.default,
      choices: arg.choices as string[] | undefined,
    };
  }

  // Handle simplified format
  const keys = Object.keys(arg);
  const name = keys[0] ?? 'arg';
  const desc = arg[name];

  return {
    name,
    description: String(desc ?? ''),
    type: 'string',
    required: false,
  };
}

// =============================================================================
// Argument Parsing
// =============================================================================

/**
 * Parse command-line style arguments
 */
export function parseSkillArgs(
  skill: Skill,
  rawArgs: string
): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  const definitions = skill.arguments || [];

  // Apply defaults
  for (const def of definitions) {
    if (def.default !== undefined) {
      args[def.name] = def.default;
    }
  }

  // Parse positional and named arguments
  const tokens = tokenize(rawArgs);
  let positionalIndex = 0;
  const positionalArgs = definitions.filter(d => d.required !== false);

  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (!token) continue;

    // Named argument (--name value or --name=value)
    if (token.startsWith('--')) {
      const parts = token.slice(2).split('=');
      const name = parts[0] ?? '';
      const value = parts[1];
      const def = definitions.find(d => d.name === name);

      if (def && name) {
        if (value !== undefined) {
          args[name] = convertValue(value, def.type);
        } else if (def.type === 'boolean') {
          args[name] = true;
        } else {
          const nextToken = tokens[i + 1];
          if (i + 1 < tokens.length && nextToken && !nextToken.startsWith('-')) {
            i++;
            args[name] = convertValue(nextToken, def.type);
          }
        }
      }
      continue;
    }

    // Short argument (-n value)
    if (token.startsWith('-') && token.length === 2) {
      const shortName = token[1] ?? '';
      const def = definitions.find(d => d.name[0] === shortName);

      if (def) {
        if (def.type === 'boolean') {
          args[def.name] = true;
        } else {
          const nextToken = tokens[i + 1];
          if (i + 1 < tokens.length && nextToken) {
            i++;
            args[def.name] = convertValue(nextToken, def.type);
          }
        }
      }
      continue;
    }

    // Positional argument
    const posDef = positionalArgs[positionalIndex];
    if (positionalIndex < positionalArgs.length && posDef) {
      positionalIndex++;
      args[posDef.name] = convertValue(token, posDef.type);
    }
  }

  return args;
}

/**
 * Tokenize argument string
 */
function tokenize(input: string): string[] {
  const tokens: string[] = [];
  let current = '';
  let inQuotes = false;
  let quoteChar = '';

  for (const char of input) {
    if ((char === '"' || char === "'") && !inQuotes) {
      inQuotes = true;
      quoteChar = char;
      continue;
    }

    if (char === quoteChar && inQuotes) {
      inQuotes = false;
      if (current) tokens.push(current);
      current = '';
      continue;
    }

    if (char === ' ' && !inQuotes) {
      if (current) tokens.push(current);
      current = '';
      continue;
    }

    current += char;
  }

  if (current) tokens.push(current);

  return tokens;
}

/**
 * Convert value to expected type
 */
function convertValue(value: string, type: SkillArgument['type']): unknown {
  switch (type) {
    case 'number':
      return Number(value);
    case 'boolean':
      return value.toLowerCase() === 'true' || value === '1';
    case 'array':
      return value.split(',').map(s => s.trim());
    default:
      return value;
  }
}
