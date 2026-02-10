/**
 * @fileoverview Skill System Types
 *
 * Type definitions for the Tron Skills system. Skills are folders containing
 * a SKILL.md file with optional YAML frontmatter and additional files/scripts.
 *
 * Skills can be:
 * - Global: Located in ~/.tron/skills/ (shared across all projects)
 * - Project: Located in .tron/skills/ (project-specific, takes precedence)
 */

// =============================================================================
// Frontmatter Types
// =============================================================================

/**
 * Granular deny rule for specific tool parameters.
 * Blocks specific invocations of a tool based on parameter patterns.
 */
export interface SkillDeniedPatternRule {
  /** Tool name this rule applies to */
  tool: string;
  /** Parameter patterns that trigger denial */
  denyPatterns: { parameter: string; patterns: string[] }[];
  /** Optional custom denial message */
  message?: string;
}

/**
 * Subagent execution mode for skills.
 *
 * - 'no' (default): Inject skill into current agent. Tool preferences are suggestions only.
 * - 'ask': Prompt user whether to run in current agent or spawn subagent.
 * - 'yes': Always spawn subagent with enforced tool restrictions.
 */
export type SkillSubagentMode = 'no' | 'ask' | 'yes';

/**
 * YAML frontmatter parsed from SKILL.md
 */
export interface SkillFrontmatter {
  /** Human-readable name for display (falls back to folder name if not set) */
  name?: string;
  /** Short description of what this skill does */
  description?: string;
  /** Semantic version of the skill */
  version?: string;
  /** Tags for categorization and filtering */
  tags?: string[];

  // ============================================================================
  // Tool Restriction System
  // ============================================================================

  /**
   * Tools this skill needs (allow-list mode, for third-party/imported skills).
   * Enforcement depends on subagent mode:
   * - subagent: 'no' → Strong suggestion in skill prompt (no enforcement)
   * - subagent: 'yes' → Enforced via ToolDenialConfig (everything else blocked)
   * Mutually exclusive with deniedTools.
   */
  allowedTools?: string[];

  /**
   * Tools to block entirely (deny-list mode, primary for first-party skills).
   * Enforcement depends on subagent mode:
   * - subagent: 'no' → Noted as restrictions in skill prompt
   * - subagent: 'yes' → Enforced via ToolDenialConfig
   * Mutually exclusive with allowedTools.
   */
  deniedTools?: string[];

  /**
   * Granular deny rules for specific tool parameters.
   * Only enforced when subagent: 'yes'.
   */
  deniedPatterns?: SkillDeniedPatternRule[];

  /**
   * Subagent execution mode.
   * - 'no' (default): Run in current agent (tools are suggestions)
   * - 'ask': Prompt user for choice
   * - 'yes': Spawn subagent (tools are enforced)
   */
  subagent?: SkillSubagentMode;

  /**
   * Model to use when spawning subagent (only used when subagent != 'no').
   */
  subagentModel?: string;
}

// =============================================================================
// Skill Metadata Types
// =============================================================================

/** Source location of a skill */
export type SkillSource = 'global' | 'project';

/**
 * Full metadata for a loaded skill
 */
export interface SkillMetadata {
  /** Skill name (folder name, used as @reference) */
  name: string;
  /** Human-readable display name (from frontmatter, falls back to folder name) */
  displayName: string;
  /** Short description (from frontmatter or first non-header line of SKILL.md) */
  description: string;
  /** Full SKILL.md content (after frontmatter stripped) */
  content: string;
  /** Parsed frontmatter from SKILL.md */
  frontmatter: SkillFrontmatter;
  /** Where the skill was loaded from */
  source: SkillSource;
  /** Absolute path to skill folder */
  path: string;
  /** Absolute path to SKILL.md file */
  skillMdPath: string;
  /** List of additional files in the skill folder */
  additionalFiles: string[];
  /** Last modification timestamp (for cache invalidation) */
  lastModified: number;
}

/**
 * Lightweight skill info for listing (excludes full content)
 */
export interface SkillInfo {
  name: string;
  displayName: string;
  description: string;
  source: SkillSource;
  tags?: string[];
}

// =============================================================================
// Reference Extraction Types
// =============================================================================

/**
 * A skill reference found in user input (e.g., @browser)
 */
export interface SkillReference {
  /** Original text as typed (e.g., "@browser") */
  original: string;
  /** Extracted skill name (e.g., "browser") */
  name: string;
  /** Position in the original string */
  position: {
    start: number;
    end: number;
  };
}

// =============================================================================
// Injection Types
// =============================================================================

/**
 * Result of processing a prompt for skill injection
 */
export interface SkillInjectionResult {
  /** Original user prompt before processing */
  originalPrompt: string;
  /** Prompt with @references removed */
  cleanedPrompt: string;
  /** Skills that were successfully injected */
  injectedSkills: SkillMetadata[];
  /** Skill names that were referenced but not found */
  notFoundSkills: string[];
  /** Generated <skills>...</skills> XML block */
  skillContext: string;
}

// =============================================================================
// Loader Types
// =============================================================================

/**
 * Result of scanning a skills directory
 */
export interface SkillScanResult {
  /** Skills found in the directory */
  skills: SkillMetadata[];
  /** Errors encountered during scanning */
  errors: SkillScanError[];
}

/**
 * Error encountered while scanning/loading a skill
 */
export interface SkillScanError {
  /** Path to the problematic skill folder */
  path: string;
  /** Error message */
  message: string;
  /** Whether loading can continue */
  recoverable: boolean;
}

// =============================================================================
// Registry Types
// =============================================================================

/**
 * Options for listing skills
 */
export interface SkillListOptions {
  /** Filter by source */
  source?: SkillSource;
  /** Include full content in results */
  includeContent?: boolean;
}

/**
 * Options for skill registry initialization
 */
export interface SkillRegistryOptions {
  /** Working directory for project skills */
  workingDirectory: string;
  /** Global skills directory (defaults to ~/.tron/skills) */
  globalSkillsDir?: string;
  /** Project skills directory name (defaults to .tron/skills) */
  projectSkillsDirName?: string;
}

// =============================================================================
// Skill Tracking Types (for session context management)
// =============================================================================

/** How a skill was added to the session context */
export type SkillAddMethod = 'mention' | 'explicit';

/** How a skill was removed from context */
export type SkillRemoveReason = 'manual' | 'clear' | 'compact';

/**
 * Payload for skill.added event
 */
export interface SkillAddedPayload {
  /** Name of the skill that was added */
  skillName: string;
  /** Source of the skill (global or project) */
  source: SkillSource;
  /** How the skill was added (via @mention or explicit sheet selection) */
  addedVia: SkillAddMethod;
}

/**
 * Payload for skill.removed event
 */
export interface SkillRemovedPayload {
  /** Name of the skill that was removed */
  skillName: string;
  /** Why the skill was removed */
  removedVia: SkillRemoveReason;
}

/**
 * Information about a skill that has been added to session context.
 * Used in DetailedContextSnapshot response.
 */
export interface AddedSkillInfo {
  /** Skill name */
  name: string;
  /** Source of the skill */
  source: SkillSource;
  /** How the skill was added */
  addedVia: SkillAddMethod;
  /** Event ID for removal tracking */
  eventId: string;
}
