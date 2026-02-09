/**
 * @fileoverview Worktree Adapter
 *
 * Adapts EventStoreOrchestrator's WorktreeController to the WorktreeRpcManager
 * interface expected by RpcContext.
 */

import type { AdapterDependencies, WorktreeManagerAdapter } from '../types.js';

/**
 * Creates a WorktreeController adapter from EventStoreOrchestrator
 */
export function createWorktreeAdapter(deps: AdapterDependencies): WorktreeManagerAdapter {
  const { orchestrator } = deps;

  return {
    async getWorktreeStatus(sessionId) {
      return orchestrator.worktree.getStatus(sessionId);
    },
    async commitWorktree(sessionId, message) {
      return orchestrator.worktree.commit(sessionId, message);
    },
    async mergeWorktree(sessionId, targetBranch, strategy) {
      return orchestrator.worktree.merge(sessionId, targetBranch, strategy);
    },
    async listWorktrees() {
      return orchestrator.worktree.list();
    },
  };
}
