/**
 * @fileoverview Command System Exports
 */

export type {
  Command,
  CommandContext,
  CommandHandler,
  CommandOption,
  ParsedCommand,
  CommandMatch,
} from './types.js';

export {
  BUILT_IN_COMMANDS,
  getCommands,
  findCommand,
  getCommandsByCategory,
  canExecuteCommand,
} from './registry.js';

export {
  isCommand,
  parseCommand,
  getPartialCommand,
  filterCommands,
  getTopMatches,
} from './parser.js';
