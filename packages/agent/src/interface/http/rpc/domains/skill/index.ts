/**
 * @fileoverview Skill domain - Skill loading and management
 *
 * Handles skill listing, retrieval, refresh, and removal.
 */

// Re-export handler factory
export { createSkillHandlers } from '@interface/rpc/handlers/skill.handler.js';

// Re-export types
export type {
  SkillListParams,
  SkillListResult,
  SkillGetParams,
  SkillGetResult,
  SkillRefreshParams,
  SkillRefreshResult,
  SkillRemoveParams,
  SkillRemoveResult,
} from '@interface/rpc/types/skill.js';
