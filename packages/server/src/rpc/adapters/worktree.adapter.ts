/**
 * @fileoverview Worktree Adapter
 *
 * Adapts EventStoreOrchestrator worktree methods to the WorktreeRpcManager
 * interface expected by RpcContext.
 */

import type { AdapterDependencies, WorktreeManagerAdapter } from '../types.js';

/**
 * Creates a WorktreeManager adapter from EventStoreOrchestrator
 */
export function createWorktreeAdapter(deps: AdapterDependencies): WorktreeManagerAdapter {
  const { orchestrator } = deps;

  return {
    async getWorktreeStatus(sessionId) {
      return orchestrator.getWorktreeStatus(sessionId);
    },
    async commitWorktree(sessionId, message) {
      return orchestrator.commitWorktree(sessionId, message);
    },
    async mergeWorktree(sessionId, targetBranch, strategy) {
      return orchestrator.mergeWorktree(sessionId, targetBranch, strategy);
    },
    async listWorktrees() {
      return orchestrator.listWorktrees();
    },
  };
}
