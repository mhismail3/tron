/**
 * @fileoverview Slash Command System
 *
 * Provides built-in slash commands for the TUI.
 * Commands are triggered by typing / at the start of input.
 */

// =============================================================================
// Types
// =============================================================================

export interface SlashCommand {
  name: string;
  description: string;
  shortcut?: string;
  handler?: (args: string[]) => void | Promise<void>;
}

export interface ParsedCommand {
  commandName: string;
  args: string[];
}

// =============================================================================
// Built-in Commands
// =============================================================================

export const BUILT_IN_COMMANDS: SlashCommand[] = [
  {
    name: 'model',
    description: 'Change the current model',
    shortcut: 'm',
  },
  {
    name: 'help',
    description: 'Show available commands and keyboard shortcuts',
    shortcut: 'h',
  },
  {
    name: 'clear',
    description: 'Clear the message history',
    shortcut: 'c',
  },
  {
    name: 'context',
    description: 'View loaded context and AGENTS.md files',
  },
  {
    name: 'session',
    description: 'Show current session information',
  },
  {
    name: 'history',
    description: 'View conversation history',
  },
  {
    name: 'exit',
    description: 'Exit the application',
    shortcut: 'q',
  },
];

// =============================================================================
// Parser Functions
// =============================================================================

/**
 * Check if input is a potential slash command (starts with /)
 */
export function isSlashCommandInput(input: string): boolean {
  return input.startsWith('/');
}

/**
 * Parse a slash command input into command name and arguments
 */
export function parseSlashCommand(input: string): ParsedCommand {
  // Remove leading /
  const withoutSlash = input.slice(1);

  // Split by whitespace
  const parts = withoutSlash.split(/\s+/).filter(Boolean);

  if (parts.length === 0) {
    return { commandName: '', args: [] };
  }

  const [commandName, ...args] = parts;
  return { commandName: commandName ?? '', args };
}

/**
 * Filter commands by prefix or description match
 */
export function filterCommands(commands: SlashCommand[], filter: string): SlashCommand[] {
  if (!filter) {
    return commands;
  }

  const lowerFilter = filter.toLowerCase();

  return commands.filter(cmd => {
    const nameMatch = cmd.name.toLowerCase().startsWith(lowerFilter);
    const descMatch = cmd.description.toLowerCase().includes(lowerFilter);
    return nameMatch || descMatch;
  });
}

/**
 * Find an exact command match by name or shortcut
 */
export function findCommand(commands: SlashCommand[], nameOrShortcut: string): SlashCommand | undefined {
  const lower = nameOrShortcut.toLowerCase();
  return commands.find(cmd =>
    cmd.name.toLowerCase() === lower ||
    cmd.shortcut?.toLowerCase() === lower
  );
}
