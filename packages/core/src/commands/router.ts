/**
 * @fileoverview Command Router
 *
 * Routes slash commands to skills or built-in handlers.
 */

import { createLogger } from '../logging/index.js';
import { createSkillRegistry } from '../skills/registry.js';
import { createSkillLoader } from '../skills/loader.js';
import { createSkillExecutor } from '../skills/executor.js';
import type { ISkillRegistry } from '../skills/types.js';
import type {
  ICommandRouter,
  ParsedCommand,
  CommandResult,
  CommandContext,
  CommandRouterConfig,
  BuiltInCommand,
} from './types.js';
import { parseCommand, getCommandSuggestions, formatCommand } from './parser.js';
import { getDefaultBuiltInCommands } from './builtins.js';

// Import version directly to avoid circular dependency
const VERSION = '0.1.0';

const log = createLogger('commands:router');

/**
 * Command Router implementation
 */
export class CommandRouter implements ICommandRouter {
  private registry: ISkillRegistry;
  private executor: ReturnType<typeof createSkillExecutor>;
  private loader: ReturnType<typeof createSkillLoader>;
  private builtInCommands: Map<string, BuiltInCommand> = new Map();
  private initialized = false;
  private config: CommandRouterConfig;

  constructor(config: CommandRouterConfig = {}) {
    this.config = config;
    this.registry = createSkillRegistry();
    this.executor = createSkillExecutor();
    this.loader = createSkillLoader(config.skillDirs || []);
  }

  /**
   * Initialize the router - load skills and register commands
   */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }

    log.info('Initializing command router');

    // Load and register skills
    const skills = await this.loader.discover();
    this.registry.registerAll(skills);

    log.info({ skillCount: skills.length }, 'Skills loaded');

    // Register default built-in commands
    const defaultCommands = getDefaultBuiltInCommands({
      version: VERSION,
      getCommandList: () => this.listCommands(),
      getCommandHelp: (cmd) => this.getHelp(cmd),
    });

    for (const cmd of defaultCommands) {
      this.registerBuiltIn(cmd);
    }

    // Register custom built-in commands
    if (this.config.customCommands) {
      for (const cmd of this.config.customCommands) {
        this.registerBuiltIn(cmd);
      }
    }

    this.initialized = true;
    log.info('Command router initialized');
  }

  /**
   * Register a built-in command
   */
  registerBuiltIn(command: BuiltInCommand): void {
    this.builtInCommands.set(command.name.toLowerCase(), command);
    log.debug({ command: command.name }, 'Built-in command registered');
  }

  /**
   * Parse user input into a command
   */
  parse(input: string): ParsedCommand {
    return parseCommand(input);
  }

  /**
   * Execute a parsed command
   */
  async execute(
    parsed: ParsedCommand,
    context: CommandContext = {}
  ): Promise<CommandResult> {
    if (!this.initialized) {
      await this.initialize();
    }

    if (!parsed.isCommand) {
      return {
        success: false,
        error: 'Not a valid command',
        requiresAgent: false,
      };
    }

    const commandName = parsed.command.toLowerCase();

    log.debug({ command: commandName, args: parsed.rawArgs }, 'Executing command');

    // Check built-in commands first
    const builtIn = this.builtInCommands.get(commandName);
    if (builtIn) {
      try {
        const result = await builtIn.handler(parsed.rawArgs, context);
        log.debug({ command: commandName, success: result.success }, 'Built-in command executed');
        return result;
      } catch (error) {
        log.error({ command: commandName, error }, 'Built-in command failed');
        return {
          success: false,
          error: error instanceof Error ? error.message : 'Command execution failed',
          requiresAgent: false,
        };
      }
    }

    // Look up skill by command
    const skill = this.registry.getByCommand(commandName);
    if (!skill) {
      log.warn({ command: commandName }, 'Unknown command');
      return {
        success: false,
        error: `Unknown command: ${formatCommand(commandName)}`,
        requiresAgent: false,
      };
    }

    // Execute the skill
    try {
      const executionResult = await this.executor.execute(skill, parsed.rawArgs, {
        workingDirectory: context.workingDirectory,
        sessionId: context.sessionId,
        userId: context.userId,
        ...context.metadata,
      });

      if (!executionResult.success) {
        return {
          success: false,
          error: executionResult.error,
          skill,
          executionResult,
          requiresAgent: false,
        };
      }

      log.info({ command: commandName, skill: skill.id }, 'Skill executed');

      return {
        success: true,
        prompt: executionResult.prompt,
        skill,
        executionResult,
        requiresAgent: true, // Skill prompts need agent processing
      };
    } catch (error) {
      log.error({ command: commandName, error }, 'Skill execution failed');
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Skill execution failed',
        skill,
        requiresAgent: false,
      };
    }
  }

  /**
   * Execute from raw input
   */
  async executeRaw(
    input: string,
    context: CommandContext = {}
  ): Promise<CommandResult> {
    const parsed = this.parse(input);
    return this.execute(parsed, context);
  }

  /**
   * Get help for a specific command
   */
  getHelp(command: string): string | null {
    const normalized = command.toLowerCase().replace(/^\//, '');

    // Check built-in commands
    const builtIn = this.builtInCommands.get(normalized);
    if (builtIn) {
      const lines = [
        `# ${formatCommand(builtIn.name)}`,
        '',
        builtIn.description,
      ];

      if (builtIn.usage) {
        lines.push('', '## Usage', '', `  ${builtIn.usage}`);
      }

      return lines.join('\n');
    }

    // Check skills
    const skill = this.registry.getByCommand(normalized);
    if (skill) {
      return this.executor.getHelp(skill);
    }

    return null;
  }

  /**
   * List all available commands
   */
  listCommands(): string[] {
    const commands = new Set<string>();

    // Add built-in commands
    for (const cmd of this.builtInCommands.keys()) {
      commands.add(cmd);
    }

    // Add skill commands
    for (const cmd of this.registry.getCommands()) {
      commands.add(cmd);
    }

    return Array.from(commands).sort();
  }

  /**
   * Check if a command exists
   */
  hasCommand(command: string): boolean {
    const normalized = command.toLowerCase().replace(/^\//, '');
    return (
      this.builtInCommands.has(normalized) ||
      this.registry.hasCommand(normalized)
    );
  }

  /**
   * Get completion suggestions for partial input
   */
  getCompletions(partial: string): string[] {
    const allCommands = this.listCommands();
    return getCommandSuggestions(partial, allCommands);
  }

  /**
   * Get the skill registry
   */
  getRegistry(): ISkillRegistry {
    return this.registry;
  }
}

/**
 * Create a command router instance
 */
export function createCommandRouter(
  config: CommandRouterConfig = {}
): CommandRouter {
  return new CommandRouter(config);
}
