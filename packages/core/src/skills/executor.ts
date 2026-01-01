/**
 * @fileoverview Skill Executor
 *
 * Executes skills with argument parsing and context building.
 */
import { createLogger } from '../logging/index.js';
import { parseSkillArgs } from './parser.js';
import type {
  Skill,
  SkillExecutionContext,
  SkillExecutionResult,
} from './types.js';

const logger = createLogger('skills:executor');

// =============================================================================
// Executor
// =============================================================================

export class SkillExecutor {
  /**
   * Execute a skill with arguments
   */
  async execute(
    skill: Skill,
    rawArgs: string = '',
    context: Partial<SkillExecutionContext> = {}
  ): Promise<SkillExecutionResult> {
    try {
      // Parse arguments
      const args = parseSkillArgs(skill, rawArgs);

      // Validate required arguments
      const validation = this.validateArgs(skill, args);
      if (!validation.valid) {
        return {
          success: false,
          error: validation.error,
        };
      }

      // Build the prompt
      const prompt = this.buildPrompt(skill, args, context);

      logger.info('Skill executed', {
        skillId: skill.id,
        args: Object.keys(args),
      });

      return {
        success: true,
        prompt,
        context: {
          skill: skill.id,
          args,
        },
      };
    } catch (error) {
      logger.error('Skill execution failed', { skillId: skill.id, error });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      };
    }
  }

  /**
   * Validate arguments against skill definition
   */
  private validateArgs(
    skill: Skill,
    args: Record<string, unknown>
  ): { valid: boolean; error?: string } {
    if (!skill.arguments) {
      return { valid: true };
    }

    for (const def of skill.arguments) {
      if (def.required && !(def.name in args)) {
        return {
          valid: false,
          error: `Missing required argument: ${def.name}`,
        };
      }

      if (def.name in args && def.choices) {
        const value = args[def.name];
        if (!def.choices.includes(String(value))) {
          return {
            valid: false,
            error: `Invalid value for ${def.name}. Must be one of: ${def.choices.join(', ')}`,
          };
        }
      }
    }

    return { valid: true };
  }

  /**
   * Build the prompt from skill instructions and arguments
   */
  private buildPrompt(
    skill: Skill,
    args: Record<string, unknown>,
    context: Partial<SkillExecutionContext>
  ): string {
    let prompt = skill.instructions;

    // Replace argument placeholders
    for (const [name, value] of Object.entries(args)) {
      const placeholder = new RegExp(`\\{\\{\\s*${name}\\s*\\}\\}`, 'g');
      prompt = prompt.replace(placeholder, String(value));
    }

    // Add context header
    const header = this.buildContextHeader(skill, args, context);

    return `${header}\n\n${prompt}`;
  }

  /**
   * Build context header for the prompt
   */
  private buildContextHeader(
    skill: Skill,
    args: Record<string, unknown>,
    context: Partial<SkillExecutionContext>
  ): string {
    const lines: string[] = [
      `# Skill: ${skill.name}`,
      '',
    ];

    if (skill.description) {
      lines.push(`> ${skill.description}`);
      lines.push('');
    }

    // Add arguments section if any provided
    if (Object.keys(args).length > 0) {
      lines.push('## Arguments');
      for (const [name, value] of Object.entries(args)) {
        lines.push(`- **${name}**: ${JSON.stringify(value)}`);
      }
      lines.push('');
    }

    // Add context info
    if (context.workingDirectory) {
      lines.push(`**Working Directory**: ${context.workingDirectory}`);
    }

    if (context.sessionId) {
      lines.push(`**Session**: ${context.sessionId}`);
    }

    lines.push('');
    lines.push('## Instructions');

    return lines.join('\n');
  }

  /**
   * Get help text for a skill
   */
  getHelp(skill: Skill): string {
    const lines: string[] = [
      `# ${skill.name}`,
      '',
      skill.description,
      '',
    ];

    if (skill.command) {
      lines.push(`**Command**: /${skill.command}`);
      lines.push('');
    }

    if (skill.arguments && skill.arguments.length > 0) {
      lines.push('## Arguments');
      lines.push('');
      for (const arg of skill.arguments) {
        const required = arg.required ? ' (required)' : '';
        const defaultVal = arg.default !== undefined ? ` [default: ${arg.default}]` : '';
        lines.push(`### ${arg.name}${required}${defaultVal}`);
        lines.push(arg.description);
        if (arg.choices) {
          lines.push(`Choices: ${arg.choices.join(', ')}`);
        }
        lines.push('');
      }
    }

    if (skill.examples && skill.examples.length > 0) {
      lines.push('## Examples');
      lines.push('');
      for (const example of skill.examples) {
        lines.push(`\`${example.command}\``);
        if (example.description) {
          lines.push(`  ${example.description}`);
        }
        lines.push('');
      }
    }

    if (skill.tags && skill.tags.length > 0) {
      lines.push(`**Tags**: ${skill.tags.join(', ')}`);
    }

    return lines.join('\n');
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createSkillExecutor(): SkillExecutor {
  return new SkillExecutor();
}
