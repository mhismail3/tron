/**
 * @fileoverview Skill RPC Types
 *
 * Types for skill operations methods.
 */

// =============================================================================
// Skill Methods
// =============================================================================

/**
 * Skill info returned in list operations
 */
export interface RpcSkillInfo {
  /** Skill name (folder name, used as @reference) */
  name: string;
  /** Human-readable display name (from frontmatter, falls back to folder name) */
  displayName: string;
  /** Short description (from frontmatter or first non-header line of SKILL.md) */
  description: string;
  /** Where the skill was loaded from */
  source: 'global' | 'project';
  /** Whether this skill auto-injects into every prompt (Rules) */
  autoInject: boolean;
  /** Tags for categorization */
  tags?: string[];
}

/**
 * Full skill metadata with content
 */
export interface RpcSkillMetadata extends RpcSkillInfo {
  /** Full SKILL.md content (after frontmatter stripped) */
  content: string;
  /** Absolute path to skill folder */
  path: string;
  /** List of additional files in the skill folder */
  additionalFiles: string[];
}

/** List available skills */
export interface SkillListParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
  /** Filter by source (global, project) */
  source?: 'global' | 'project';
  /** Filter for auto-inject skills only */
  autoInjectOnly?: boolean;
  /** Include full content in results */
  includeContent?: boolean;
}

export interface SkillListResult {
  /** List of skills (with or without content based on includeContent param) */
  skills: RpcSkillInfo[] | RpcSkillMetadata[];
  /** Total number of skills */
  totalCount: number;
  /** Number of auto-inject skills (Rules) */
  autoInjectCount: number;
}

/** Get a single skill by name */
export interface SkillGetParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
  /** Skill name */
  name: string;
}

export interface SkillGetResult {
  /** Skill metadata with full content */
  skill: RpcSkillMetadata | null;
  /** Whether the skill was found */
  found: boolean;
}

/** Refresh skills cache */
export interface SkillRefreshParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
}

export interface SkillRefreshResult {
  /** Whether the refresh was successful */
  success: boolean;
  /** Number of skills loaded after refresh */
  skillCount: number;
}

/** Remove a skill from session context */
export interface SkillRemoveParams {
  /** Session ID */
  sessionId: string;
  /** Name of the skill to remove */
  skillName: string;
}

export interface SkillRemoveResult {
  /** Whether the skill was successfully removed */
  success: boolean;
  /** Error message if removal failed */
  error?: string;
}
