/**
 * @fileoverview Skill System Types
 *
 * Type definitions for the Tron Skills system. Skills are folders containing
 * a SKILL.md file with optional YAML frontmatter and additional files/scripts.
 *
 * Skills can be:
 * - Global: Located in ~/.tron/skills/ (shared across all projects)
 * - Project: Located in .tron/skills/ (project-specific, takes precedence)
 *
 * Skills with autoInject: true act as "Rules" and are automatically included
 * in every prompt without explicit reference.
 */

// =============================================================================
// Frontmatter Types
// =============================================================================

/**
 * YAML frontmatter parsed from SKILL.md
 */
export interface SkillFrontmatter {
  /** Auto-inject this skill into every prompt (acts as a "Rule") */
  autoInject?: boolean;
  /** Semantic version of the skill */
  version?: string;
  /** Tools this skill is designed to work with */
  tools?: string[];
  /** Tags for categorization and filtering */
  tags?: string[];
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
  /** Short description (first non-header line of SKILL.md) */
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
  description: string;
  source: SkillSource;
  autoInject: boolean;
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
  /** Filter for auto-inject skills only */
  autoInjectOnly?: boolean;
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
