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
      return orchestrator.getContextSnapshot(sessionId);
    },

    getDetailedContextSnapshot(sessionId) {
      const snapshot = orchestrator.getDetailedContextSnapshot(sessionId);
      const active = orchestrator.getActiveSession(sessionId);

      // Add skill tracking info from session
      const addedSkills = active?.skillTracker.getAddedSkills() ?? [];

      // Add rules tracking info from session
      const rulesTracker = active?.rulesTracker;
      const rules = rulesTracker && rulesTracker.hasRules()
        ? {
            files: rulesTracker.getRulesFiles().map(f => ({
              path: f.path,
              relativePath: f.relativePath,
              level: f.level,
              depth: f.depth,
            })),
            totalFiles: rulesTracker.getTotalFiles(),
            tokens: rulesTracker.getMergedTokens(),
          }
        : undefined;

      return {
        ...snapshot,
        addedSkills: addedSkills.map(s => ({
          name: s.name,
          source: s.source,
          addedVia: s.addedVia,
          eventId: s.eventId,
        })),
        rules,
      };
    },

    shouldCompact(sessionId) {
      return orchestrator.shouldCompact(sessionId);
    },

    async previewCompaction(sessionId) {
      return orchestrator.previewCompaction(sessionId);
    },

    async confirmCompaction(sessionId, opts) {
      return orchestrator.confirmCompaction(sessionId, opts);
    },

    canAcceptTurn(sessionId, opts) {
      return orchestrator.canAcceptTurn(sessionId, opts);
    },

    async clearContext(sessionId) {
      return orchestrator.clearContext(sessionId);
    },
  };
}
