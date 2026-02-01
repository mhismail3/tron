/**
 * @fileoverview Tree domain - Session tree visualization
 *
 * Handles tree visualization, branches, subtrees, and ancestors.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleTreeGetVisualization,
  handleTreeGetBranches,
  handleTreeGetSubtree,
  handleTreeGetAncestors,
  createTreeHandlers,
} from '../../../../rpc/handlers/tree.handler.js';

// Re-export types
export type {
  TreeGetVisualizationParams,
  TreeGetVisualizationResult,
  TreeGetBranchesParams,
  TreeGetBranchesResult,
  TreeGetSubtreeParams,
  TreeGetSubtreeResult,
  TreeGetAncestorsParams,
  TreeGetAncestorsResult,
} from '../../../../rpc/types/tree.js';
