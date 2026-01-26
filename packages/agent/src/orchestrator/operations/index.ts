/**
 * @fileoverview Domain Operations Module
 *
 * Operations for domain-specific orchestrator functionality:
 *
 * - ContextOps: Context management (snapshots, compaction, clearing)
 * - SubagentOperations: Sub-agent spawning and querying
 * - WorktreeOps: Worktree information helpers
 * - SkillLoader: Skill loading and content transformation
 */

// Context operations
export {
  ContextOps,
  createContextOps,
  type ContextOpsConfig,
} from './context-ops.js';

// Sub-agent operations
export {
  SubagentOperations,
  createSubagentOperations,
  type SubagentOperationsConfig,
  type SpawnSubagentResult,
  type SpawnTmuxAgentResult,
  type QuerySubagentResult,
  type WaitForSubagentsResult,
} from './subagent-ops/index.js';

// Worktree operations
export {
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './worktree-ops.js';

// Skill loading
export {
  SkillLoader,
  createSkillLoader,
  type SkillLoaderConfig,
  type SkillLoadContext,
} from './skill-loader.js';
