/**
 * @fileoverview Slash Command Types
 *
 * Types for slash command parsing, routing, and execution.
 */

/**
 * Parsed slash command from user input
 */
export interface ParsedCommand {
  /** The command name (without leading slash) */
  command: string;
  /** Raw arguments string after the command */
  rawArgs: string;
  /** Original full input string */
  original: string;
  /** Whether this looks like a slash command */
  isCommand: boolean;
}

/**
 * Command execution context
 */
export interface CommandContext {
  /** Current working directory */
  workingDirectory?: string;
  /** Current session ID */
  sessionId?: string;
  /** User ID */
  userId?: string;
  /** Additional metadata */
  metadata?: Record<string, unknown>;
}

/**
 * Result of command execution
 */
export interface CommandResult {
  /** Whether execution succeeded */
  success: boolean;
  /** Generated prompt to send to agent (if any) */
  prompt?: string;
  /** Output to display to user */
  output?: string;
  /** Error message if failed */
  error?: string;
  /** Whether this command requires agent processing */
  requiresAgent: boolean;
}

/**
 * Built-in command handler function
 */
export type BuiltInCommandHandler = (
  args: string,
  context: CommandContext
) => Promise<CommandResult> | CommandResult;

/**
 * Built-in command definition
 */
export interface BuiltInCommand {
  /** Command name (without slash) */
  name: string;
  /** Short description */
  description: string;
  /** Usage pattern */
  usage?: string;
  /** Command handler */
  handler: BuiltInCommandHandler;
  /** Whether this is a system command (not a skill) */
  isSystem?: boolean;
}

/**
 * Command router configuration
 */
export interface CommandRouterConfig {
  /** Custom built-in commands */
  customCommands?: BuiltInCommand[];
}

/**
 * Command router interface
 */
export interface ICommandRouter {
  /** Initialize the router */
  initialize(): Promise<void>;

  /** Parse user input into a command */
  parse(input: string): ParsedCommand;

  /** Execute a parsed command */
  execute(parsed: ParsedCommand, context?: CommandContext): Promise<CommandResult>;

  /** Execute from raw input */
  executeRaw(input: string, context?: CommandContext): Promise<CommandResult>;

  /** Get help for a specific command */
  getHelp(command: string): string | null;

  /** List all available commands */
  listCommands(): string[];

  /** Check if a command exists */
  hasCommand(command: string): boolean;

  /** Get completion suggestions for partial input */
  getCompletions(partial: string): string[];
}
