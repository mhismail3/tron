/**
 * @fileoverview Skill Loader
 *
 * Discovers and loads skills from directories.
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../logging/index.js';
import { parseSkillFile, buildSkillFromParsed } from './parser.js';
import type { Skill, SkillLoaderConfig } from './types.js';

const logger = createLogger('skills:loader');

// =============================================================================
// Built-in Skills
// =============================================================================

const BUILT_IN_SKILLS: Skill[] = [
  {
    id: 'commit',
    name: 'Commit',
    description: 'Create a git commit with a descriptive message',
    command: 'commit',
    builtIn: true,
    arguments: [
      {
        name: 'message',
        description: 'Commit message (optional, will auto-generate if not provided)',
        type: 'string',
        required: false,
      },
    ],
    instructions: `Create a git commit for the current changes.

## Steps:
1. Run \`git status\` to see current changes
2. Run \`git diff --staged\` to see staged changes
3. If no staged changes, suggest running \`git add\` first
4. Generate a descriptive commit message following conventional commits format
5. Create the commit

## Guidelines:
- Use conventional commit format: type(scope): description
- Types: feat, fix, docs, style, refactor, test, chore
- Keep first line under 50 characters
- Add body for complex changes
`,
  },
  {
    id: 'handoff',
    name: 'Handoff',
    description: 'Create a handoff document for session continuity',
    command: 'handoff',
    builtIn: true,
    instructions: `Create a handoff document summarizing the current session.

## Include:
1. **Summary**: What was accomplished
2. **Code Changes**: Files modified with brief descriptions
3. **Current State**: Where things stand now
4. **Blockers**: Any issues preventing progress
5. **Next Steps**: What should be done next
6. **Patterns Discovered**: Any useful patterns or learnings

Save to thoughts/shared/handoffs/ with timestamp.
`,
  },
  {
    id: 'ledger',
    name: 'Ledger',
    description: 'Update the session continuity ledger',
    command: 'ledger',
    builtIn: true,
    arguments: [
      {
        name: 'action',
        description: 'Action to perform: view, update, goal, done, next',
        type: 'string',
        required: false,
        default: 'view',
      },
    ],
    instructions: `Manage the session continuity ledger.

## Actions:
- **view**: Display current ledger state
- **update**: Interactively update ledger sections
- **goal**: Set or update the current goal
- **done**: Mark a task as done
- **next**: Add an item to next steps

The ledger tracks:
- Goal: Current objective
- Constraints: Limitations to respect
- Done: Completed tasks
- Now: Current focus
- Next: Upcoming tasks
- Key Decisions: Important choices made
- Working Files: Files currently being edited
`,
  },
  {
    id: 'clear',
    name: 'Clear',
    description: 'Clear the conversation context',
    command: 'clear',
    builtIn: true,
    instructions: `Clear the current conversation context.

This will:
1. Preserve the session ID
2. Preserve the ledger state
3. Clear all messages
4. Optionally create a handoff before clearing

Ask user if they want to create a handoff first.
`,
  },
  {
    id: 'context',
    name: 'Context',
    description: 'Show context usage and token breakdown',
    command: 'context',
    builtIn: true,
    instructions: `Display current context usage statistics.

Show:
1. Total tokens used
2. Breakdown by type (system, user, assistant, tools)
3. Context window percentage used
4. Estimated remaining capacity
5. Suggestions if running low on context
`,
  },
  {
    id: 'export',
    name: 'Export',
    description: 'Export the conversation transcript',
    command: 'export',
    builtIn: true,
    arguments: [
      {
        name: 'format',
        description: 'Export format',
        type: 'string',
        required: false,
        default: 'markdown',
        choices: ['markdown', 'html', 'json', 'text'],
      },
      {
        name: 'output',
        description: 'Output file path',
        type: 'string',
        required: false,
      },
    ],
    instructions: `Export the conversation transcript.

Formats:
- **markdown**: GitHub-flavored markdown
- **html**: Styled HTML with embedded CSS
- **json**: Structured JSON
- **text**: Plain text

Options:
- Include/exclude tool calls
- Include/exclude thinking blocks
- Include session metadata
`,
  },
];

// =============================================================================
// Skill Loader
// =============================================================================

export class SkillLoader {
  private config: SkillLoaderConfig;

  constructor(config: SkillLoaderConfig) {
    this.config = {
      includeBuiltIn: true,
      patterns: ['SKILL.md', '*.skill.md'],
      ...config,
    };
  }

  /**
   * Discover all skills from configured directories
   */
  async discover(): Promise<Skill[]> {
    const skills: Skill[] = [];

    // Add built-in skills
    if (this.config.includeBuiltIn) {
      skills.push(...BUILT_IN_SKILLS);
      logger.debug('Loaded built-in skills', { count: BUILT_IN_SKILLS.length });
    }

    // Load from directories
    for (const dir of this.config.skillDirs) {
      try {
        const dirSkills = await this.loadFromDirectory(dir);
        skills.push(...dirSkills);
      } catch (error) {
        logger.warn('Error loading skills from directory', { dir, error });
      }
    }

    logger.info('Skills discovered', { total: skills.length });
    return skills;
  }

  /**
   * Load skills from a directory
   */
  async loadFromDirectory(dir: string): Promise<Skill[]> {
    const skills: Skill[] = [];

    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          // Check for SKILL.md in subdirectory
          const skillFile = path.join(fullPath, 'SKILL.md');
          try {
            await fs.access(skillFile);
            const skill = await this.loadFromFile(skillFile);
            skills.push(skill);
          } catch {
            // No SKILL.md in this directory
          }
        } else if (this.matchesPattern(entry.name)) {
          const skill = await this.loadFromFile(fullPath);
          skills.push(skill);
        }
      }
    } catch {
      // Directory doesn't exist or not readable
    }

    return skills;
  }

  /**
   * Load a skill from a file
   */
  async loadFromFile(filePath: string): Promise<Skill> {
    const content = await fs.readFile(filePath, 'utf-8');
    const parsed = parseSkillFile(content);
    const skill = buildSkillFromParsed(parsed, filePath);

    logger.debug('Loaded skill from file', { id: skill.id, path: filePath });
    return skill;
  }

  /**
   * Load a specific skill by ID
   */
  async load(id: string): Promise<Skill | null> {
    // Check built-in skills first
    const builtIn = BUILT_IN_SKILLS.find(s => s.id === id || s.command === id);
    if (builtIn) {
      return builtIn;
    }

    // Search directories
    for (const dir of this.config.skillDirs) {
      try {
        const skillDir = path.join(dir, id);
        const skillFile = path.join(skillDir, 'SKILL.md');

        try {
          await fs.access(skillFile);
          return this.loadFromFile(skillFile);
        } catch {
          // Try direct file
          const directFile = path.join(dir, `${id}.skill.md`);
          try {
            await fs.access(directFile);
            return this.loadFromFile(directFile);
          } catch {
            // Not in this directory
          }
        }
      } catch {
        // Directory error
      }
    }

    return null;
  }

  /**
   * Check if filename matches configured patterns
   */
  private matchesPattern(filename: string): boolean {
    for (const pattern of this.config.patterns || []) {
      if (pattern === filename) return true;
      if (pattern.startsWith('*.') && filename.endsWith(pattern.slice(1))) return true;
    }
    return false;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createSkillLoader(skillDirs: string[]): SkillLoader {
  return new SkillLoader({ skillDirs });
}

// =============================================================================
// Exports
// =============================================================================

export { BUILT_IN_SKILLS };
