/**
 * @fileoverview Context Adapter
 *
 * Adapts EventStoreOrchestrator context methods to the ContextRpcManager
 * interface expected by RpcContext. Handles context snapshots, compaction
 * preview/execution, and context clearing.
 */

import type { AdapterDependencies, ContextManagerAdapter } from '../types.js';

/**
 * Creates a ContextManager adapter from EventStoreOrchestrator
 */
export function createContextAdapter(deps: AdapterDependencies): ContextManagerAdapter {
  const { orchestrator } = deps;

  return {
    getContextSnapshot(sessionId) {
      return orchestrator.context.getContextSnapshot(sessionId);
    },

    getDetailedContextSnapshot(sessionId) {
      // context-ops.getDetailedContextSnapshot() already assembles addedSkills,
      // rules, and memory onto the snapshot at runtime
      return orchestrator.context.getDetailedContextSnapshot(sessionId) as any;
    },

    shouldCompact(sessionId) {
      return orchestrator.context.shouldCompact(sessionId);
    },

    async previewCompaction(sessionId) {
      return orchestrator.context.previewCompaction(sessionId);
    },

    async confirmCompaction(sessionId, opts) {
      return orchestrator.context.confirmCompaction(sessionId, opts);
    },

    canAcceptTurn(sessionId, opts) {
      return orchestrator.context.canAcceptTurn(sessionId, opts);
    },

    async clearContext(sessionId) {
      return orchestrator.context.clearContext(sessionId);
    },
  };
}
