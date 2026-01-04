/**
 * @fileoverview Command Registry
 *
 * Built-in commands for the chat interface.
 */

import type { Command } from './types.js';

// =============================================================================
// Built-in Commands
// =============================================================================

export const BUILT_IN_COMMANDS: Command[] = [
  // Session Commands
  {
    name: 'session',
    description: 'Show current session info',
    category: 'session',
    requiresSession: true,
    handler: (ctx) => {
      ctx.dispatch({ type: 'ADD_SYSTEM_MESSAGE', payload: `Session: ${ctx.sessionId}` });
    },
  },
  {
    name: 'resume',
    alias: 'r',
    description: 'Resume a previous session',
    category: 'session',
    requiresSession: false,
    handler: () => {
      // Opens session list
    },
    options: [], // Populated dynamically with sessions
  },
  {
    name: 'branch',
    description: 'Fork current session',
    category: 'session',
    requiresSession: true,
    handler: () => {
      // Fork session
    },
  },
  {
    name: 'rewind',
    description: 'Rewind to a previous message',
    category: 'session',
    requiresSession: true,
    handler: () => {
      // Show message selector
    },
  },
  {
    name: 'clear',
    alias: 'c',
    description: 'Clear message display',
    category: 'session',
    requiresSession: false,
    handler: (ctx) => {
      ctx.dispatch({ type: 'CLEAR_MESSAGES' });
    },
  },

  // Model Commands
  {
    name: 'model',
    alias: 'm',
    description: 'Switch AI model',
    category: 'model',
    requiresSession: true,
    handler: () => {
      // Opens model switcher
    },
    options: [
      { value: 'claude-opus-4-20250514', label: 'Opus 4', description: 'Most capable' },
      { value: 'claude-sonnet-4-20250514', label: 'Sonnet 4', description: 'Balanced' },
      { value: 'claude-haiku-3-20240307', label: 'Haiku 3', description: 'Fast' },
    ],
  },

  // Navigation Commands
  {
    name: 'history',
    description: 'Show message history count',
    category: 'navigation',
    requiresSession: true,
    handler: (_ctx) => {
      // Show history info
    },
  },
  {
    name: 'context',
    description: 'Show loaded context',
    category: 'navigation',
    requiresSession: true,
    handler: () => {
      // Show context info
    },
  },

  // Help Commands
  {
    name: 'help',
    alias: 'h',
    description: 'Show available commands',
    category: 'help',
    requiresSession: false,
    handler: (ctx) => {
      const helpText = BUILT_IN_COMMANDS
        .map((cmd) => `/${cmd.name}${cmd.alias ? ` (/${cmd.alias})` : ''} - ${cmd.description}`)
        .join('\n');
      ctx.dispatch({ type: 'ADD_SYSTEM_MESSAGE', payload: helpText });
    },
  },

  // System Commands
  {
    name: 'exit',
    alias: 'q',
    description: 'End current session',
    category: 'system',
    requiresSession: true,
    handler: (ctx) => {
      ctx.dispatch({ type: 'RESET' });
    },
  },
];

// =============================================================================
// Registry Functions
// =============================================================================

/**
 * Get all registered commands
 */
export function getCommands(): Command[] {
  return [...BUILT_IN_COMMANDS];
}

/**
 * Find command by name or alias
 */
export function findCommand(nameOrAlias: string): Command | undefined {
  const normalized = nameOrAlias.toLowerCase();
  return BUILT_IN_COMMANDS.find(
    (cmd) => cmd.name === normalized || cmd.alias === normalized,
  );
}

/**
 * Get commands by category
 */
export function getCommandsByCategory(
  category: Command['category'],
): Command[] {
  return BUILT_IN_COMMANDS.filter((cmd) => cmd.category === category);
}

/**
 * Check if a command can be executed in current context
 */
export function canExecuteCommand(
  command: Command,
  sessionId: string | null,
): boolean {
  if (command.requiresSession && !sessionId) {
    return false;
  }
  return true;
}
