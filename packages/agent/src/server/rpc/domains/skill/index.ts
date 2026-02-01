/**
 * @fileoverview Skill domain - Skill loading and management
 *
 * Handles skill listing, retrieval, refresh, and removal.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleSkillList,
  handleSkillGet,
  handleSkillRefresh,
  handleSkillRemove,
  createSkillHandlers,
} from '../../../../rpc/handlers/skill.handler.js';

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
} from '../../../../rpc/types/skill.js';
