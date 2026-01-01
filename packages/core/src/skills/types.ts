/**
 * @fileoverview Skills System Types
 *
 * Type definitions for the skills system.
 */

// =============================================================================
// Core Types
// =============================================================================

export interface Skill {
  /** Unique skill identifier */
  id: string;
  /** Human-readable name */
  name: string;
  /** Short description */
  description: string;
  /** Slash command trigger (e.g., "commit" for /commit) */
  command?: string;
  /** Skill version */
  version?: string;
  /** Skill author */
  author?: string;
  /** Skill tags for categorization */
  tags?: string[];
  /** Arguments the skill accepts */
  arguments?: SkillArgument[];
  /** Skills this skill depends on */
  dependencies?: string[];
  /** Full instructions/prompt for the skill */
  instructions: string;
  /** Example usages */
  examples?: SkillExample[];
  /** File path where skill is defined */
  filePath?: string;
  /** Whether skill is built-in */
  builtIn?: boolean;
}

export interface SkillArgument {
  /** Argument name */
  name: string;
  /** Argument description */
  description: string;
  /** Type of the argument */
  type: 'string' | 'number' | 'boolean' | 'array';
  /** Whether argument is required */
  required?: boolean;
  /** Default value if not provided */
  default?: unknown;
  /** Valid values for enum-like arguments */
  choices?: string[];
}

export interface SkillExample {
  /** Example command/usage */
  command: string;
  /** Description of what this example does */
  description?: string;
}

// =============================================================================
// Execution Types
// =============================================================================

export interface SkillExecutionContext {
  /** The skill being executed */
  skill: Skill;
  /** Parsed arguments */
  args: Record<string, unknown>;
  /** Raw command string */
  rawCommand?: string;
  /** Session ID */
  sessionId?: string;
  /** Working directory */
  workingDirectory?: string;
  /** User ID */
  userId?: string;
}

export interface SkillExecutionResult {
  /** Whether execution was successful */
  success: boolean;
  /** Generated prompt/instructions */
  prompt?: string;
  /** Error message if failed */
  error?: string;
  /** Any additional context */
  context?: Record<string, unknown>;
}

// =============================================================================
// Loader Types
// =============================================================================

export interface SkillLoaderConfig {
  /** Directories to search for skills */
  skillDirs: string[];
  /** Whether to load built-in skills */
  includeBuiltIn?: boolean;
  /** File patterns to match */
  patterns?: string[];
}

export interface ParsedSkillFile {
  /** YAML frontmatter */
  frontmatter: SkillFrontmatter;
  /** Markdown body (instructions) */
  body: string;
}

export interface SkillFrontmatter {
  name: string;
  description: string;
  command?: string;
  version?: string;
  author?: string;
  tags?: string[];
  arguments?: SkillArgument[];
  dependencies?: string[];
  examples?: SkillExample[];
}

// =============================================================================
// Registry Types
// =============================================================================

export interface SkillRegistry {
  /** Get skill by ID */
  get(id: string): Skill | undefined;
  /** Get skill by command */
  getByCommand(command: string): Skill | undefined;
  /** List all skills */
  list(): Skill[];
  /** Register a skill */
  register(skill: Skill): void;
  /** Register multiple skills */
  registerAll(skills: Skill[]): void;
  /** Unregister a skill */
  unregister(id: string): void;
  /** Search skills */
  search(query: string): Skill[];
  /** Get all commands */
  getCommands(): string[];
  /** Check if command exists */
  hasCommand(command: string): boolean;
}

/** Alias for SkillRegistry */
export type ISkillRegistry = SkillRegistry;
