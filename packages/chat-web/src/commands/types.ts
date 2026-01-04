/**
 * @fileoverview Command System Types
 *
 * Type definitions for the slash command system.
 */

// =============================================================================
// Types
// =============================================================================

/** Command execution context */
export interface CommandContext {
  /** Current session ID */
  sessionId: string | null;
  /** Dispatch function for state updates */
  dispatch: React.Dispatch<unknown>;
  /** RPC client for server communication */
  rpc?: unknown;
}

/** Command handler function */
export type CommandHandler = (
  context: CommandContext,
  args?: string[],
) => void | Promise<void>;

/** Command definition */
export interface Command {
  /** Command name (without leading /) */
  name: string;
  /** Short alias (e.g., 'm' for 'model') */
  alias?: string;
  /** Description shown in palette */
  description: string;
  /** Category for grouping */
  category: 'session' | 'model' | 'navigation' | 'help' | 'system';
  /** Whether command requires an active session */
  requiresSession: boolean;
  /** Handler function */
  handler: CommandHandler;
  /** Sub-commands or options (for menus) */
  options?: CommandOption[];
}

/** Command option for menus */
export interface CommandOption {
  /** Option value */
  value: string;
  /** Display label */
  label: string;
  /** Optional description */
  description?: string;
}

/** Parsed command result */
export interface ParsedCommand {
  /** Command name */
  name: string;
  /** Arguments after command name */
  args: string[];
  /** Original input string */
  raw: string;
}

/** Command filter result */
export interface CommandMatch {
  /** The matched command */
  command: Command;
  /** Match score (higher = better) */
  score: number;
  /** Matched characters for highlighting */
  matchedChars: number[];
}
