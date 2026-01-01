/**
 * @fileoverview Slash Command Parser
 *
 * Parses user input to extract slash commands and arguments.
 */

import type { ParsedCommand } from './types.js';

/**
 * Regex to match slash commands at the start of input
 * Matches: /command, /command args, /command-name args
 */
const COMMAND_REGEX = /^\/([a-zA-Z][a-zA-Z0-9_-]*)\s*(.*)?$/;

/**
 * Parse user input to extract slash command
 */
export function parseCommand(input: string): ParsedCommand {
  const trimmed = input.trim();

  // Check if it starts with /
  if (!trimmed.startsWith('/')) {
    return {
      command: '',
      rawArgs: '',
      original: input,
      isCommand: false,
    };
  }

  const match = trimmed.match(COMMAND_REGEX);

  if (!match) {
    // Starts with / but doesn't match command pattern
    return {
      command: '',
      rawArgs: '',
      original: input,
      isCommand: false,
    };
  }

  const [, commandMatch, rawArgs = ''] = match;
  const command = commandMatch ?? '';

  return {
    command: command.toLowerCase(),
    rawArgs: rawArgs.trim(),
    original: input,
    isCommand: true,
  };
}

/**
 * Check if input looks like a slash command
 */
export function isSlashCommand(input: string): boolean {
  return parseCommand(input).isCommand;
}

/**
 * Extract command name from input (without parsing full command)
 */
export function extractCommandName(input: string): string | null {
  const parsed = parseCommand(input);
  return parsed.isCommand ? parsed.command : null;
}

/**
 * Normalize a command name (lowercase, trim)
 */
export function normalizeCommand(command: string): string {
  return command.toLowerCase().trim().replace(/^\//, '');
}

/**
 * Format a command for display (with leading slash)
 */
export function formatCommand(command: string): string {
  const normalized = normalizeCommand(command);
  return `/${normalized}`;
}

/**
 * Split arguments string into tokens
 * Respects quoted strings
 */
export function tokenizeArgs(argsString: string): string[] {
  const tokens: string[] = [];
  let current = '';
  let inQuotes = false;
  let quoteChar = '';

  for (let i = 0; i < argsString.length; i++) {
    const char = argsString[i];

    if ((char === '"' || char === "'") && !inQuotes) {
      inQuotes = true;
      quoteChar = char;
    } else if (char === quoteChar && inQuotes) {
      inQuotes = false;
      quoteChar = '';
    } else if (char === ' ' && !inQuotes) {
      if (current) {
        tokens.push(current);
        current = '';
      }
    } else {
      current += char;
    }
  }

  if (current) {
    tokens.push(current);
  }

  return tokens;
}

/**
 * Get command suggestions based on partial input
 */
export function getCommandSuggestions(
  partial: string,
  availableCommands: string[]
): string[] {
  const normalized = normalizeCommand(partial);

  if (!normalized) {
    return availableCommands.sort();
  }

  return availableCommands
    .filter(cmd => cmd.startsWith(normalized) || cmd.includes(normalized))
    .sort((a, b) => {
      // Prefer commands that start with the partial
      const aStarts = a.startsWith(normalized);
      const bStarts = b.startsWith(normalized);

      if (aStarts && !bStarts) return -1;
      if (!aStarts && bStarts) return 1;

      return a.localeCompare(b);
    });
}
