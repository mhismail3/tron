/**
 * @fileoverview Built-in System Commands
 *
 * System-level commands that don't require skill execution.
 */

import type { BuiltInCommand, CommandResult } from './types.js';

/**
 * Create /help command
 */
export function createHelpCommand(
  getCommandList: () => string[],
  getCommandHelp: (cmd: string) => string | null
): BuiltInCommand {
  return {
    name: 'help',
    description: 'Show help for commands',
    usage: '/help [command]',
    isSystem: true,
    handler: (args): CommandResult => {
      if (args) {
        // Help for specific command
        const help = getCommandHelp(args);
        if (help) {
          return {
            success: true,
            output: help,
            requiresAgent: false,
          };
        }
        return {
          success: false,
          error: `Unknown command: ${args}`,
          requiresAgent: false,
        };
      }

      // General help
      const commands = getCommandList();
      const output = [
        '# Available Commands\n',
        ...commands.map(cmd => `  /${cmd}`),
        '',
        'Use /help <command> for detailed help on a specific command.',
      ].join('\n');

      return {
        success: true,
        output,
        requiresAgent: false,
      };
    },
  };
}

/**
 * Create /commands command (alias for help without args)
 */
export function createCommandsCommand(
  getCommandList: () => string[]
): BuiltInCommand {
  return {
    name: 'commands',
    description: 'List all available commands',
    usage: '/commands',
    isSystem: true,
    handler: (): CommandResult => {
      const commands = getCommandList();
      const output = [
        '# Available Commands\n',
        ...commands.map(cmd => `  /${cmd}`),
      ].join('\n');

      return {
        success: true,
        output,
        requiresAgent: false,
      };
    },
  };
}

/**
 * Create /version command
 */
export function createVersionCommand(version: string): BuiltInCommand {
  return {
    name: 'version',
    description: 'Show version information',
    usage: '/version',
    isSystem: true,
    handler: (): CommandResult => {
      return {
        success: true,
        output: `Tron v${version}`,
        requiresAgent: false,
      };
    },
  };
}

/**
 * Create /status command (placeholder for session status)
 */
export function createStatusCommand(): BuiltInCommand {
  return {
    name: 'status',
    description: 'Show current session status',
    usage: '/status',
    isSystem: true,
    handler: (_, context): CommandResult => {
      const lines = ['# Session Status\n'];

      if (context.sessionId) {
        lines.push(`Session: ${context.sessionId}`);
      }
      if (context.workingDirectory) {
        lines.push(`Directory: ${context.workingDirectory}`);
      }
      if (context.userId) {
        lines.push(`User: ${context.userId}`);
      }

      lines.push(`Time: ${new Date().toISOString()}`);

      return {
        success: true,
        output: lines.join('\n'),
        requiresAgent: false,
      };
    },
  };
}

/**
 * Create /quit or /exit command
 */
export function createQuitCommand(
  onQuit: () => void | Promise<void>
): BuiltInCommand {
  return {
    name: 'quit',
    description: 'Exit the session',
    usage: '/quit',
    isSystem: true,
    handler: async (): Promise<CommandResult> => {
      await onQuit();
      return {
        success: true,
        output: 'Goodbye!',
        requiresAgent: false,
      };
    },
  };
}

/**
 * Default built-in commands
 */
export function getDefaultBuiltInCommands(options: {
  version: string;
  getCommandList: () => string[];
  getCommandHelp: (cmd: string) => string | null;
  onQuit?: () => void | Promise<void>;
}): BuiltInCommand[] {
  const commands: BuiltInCommand[] = [
    createHelpCommand(options.getCommandList, options.getCommandHelp),
    createCommandsCommand(options.getCommandList),
    createVersionCommand(options.version),
    createStatusCommand(),
  ];

  if (options.onQuit) {
    commands.push(createQuitCommand(options.onQuit));
  }

  return commands;
}
