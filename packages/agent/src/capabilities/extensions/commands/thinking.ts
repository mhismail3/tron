/**
 * @fileoverview Thinking Command
 *
 * Controls model thinking/reasoning levels for extended reasoning.
 * Levels: off, low, medium, high with different token budgets.
 */

import type { BuiltInCommand, CommandResult } from './types.js';

export type ThinkingLevel = 'off' | 'low' | 'medium' | 'high';

const THINKING_BUDGETS: Record<ThinkingLevel, number> = {
  off: 0,
  low: 1024,
  medium: 8192,
  high: 32768,
};

/**
 * Parse a thinking level string
 */
export function parseThinkingLevel(input: string): ThinkingLevel | null {
  const normalized = input.toLowerCase().trim();
  if (normalized === 'off' || normalized === 'low' || normalized === 'medium' || normalized === 'high') {
    return normalized;
  }
  return null;
}

/**
 * Get token budget for a thinking level
 */
export function getThinkingBudget(level: ThinkingLevel): number {
  return THINKING_BUDGETS[level];
}

/**
 * Configuration class for thinking levels
 */
export class ThinkingConfig {
  private _level: ThinkingLevel = 'medium';

  get level(): ThinkingLevel {
    return this._level;
  }

  get budget(): number {
    return getThinkingBudget(this._level);
  }

  get isEnabled(): boolean {
    return this._level !== 'off';
  }

  setLevel(level: ThinkingLevel): void {
    this._level = level;
  }
}

/**
 * Create the /thinking command
 */
export function createThinkingCommand(config: ThinkingConfig): BuiltInCommand {
  return {
    name: 'thinking',
    description: 'Set model thinking level (off, low, medium, high)',
    usage: '/thinking [off|low|medium|high]',
    handler: async (args: string): Promise<CommandResult> => {
      const trimmed = args.trim();

      // Show current level if no args
      if (!trimmed) {
        return {
          success: true,
          output: `Thinking level: ${config.level} (${config.budget} token budget)`,
          requiresAgent: false,
        };
      }

      // Parse and set new level
      const level = parseThinkingLevel(trimmed);
      if (!level) {
        return {
          success: false,
          error: `Invalid thinking level: "${trimmed}". Use: off, low, medium, high`,
          requiresAgent: false,
        };
      }

      config.setLevel(level);
      const budgetMsg = level === 'off' ? 'disabled' : `${config.budget} tokens`;

      return {
        success: true,
        output: `Thinking level set to ${level} (${budgetMsg})`,
        requiresAgent: false,
      };
    },
  };
}
