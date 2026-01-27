/**
 * @fileoverview Plan Adapter
 *
 * Adapts EventStoreOrchestrator plan mode methods to the PlanRpcManager
 * interface expected by RpcContext. Handles entering/exiting plan mode
 * and querying plan mode state.
 */

import { DEFAULT_PLAN_MODE_BLOCKED_TOOLS } from '../../../rpc/types/index.js';
import type { AdapterDependencies, PlanManagerAdapter } from '../types.js';

/**
 * Creates a PlanManager adapter from EventStoreOrchestrator
 */
export function createPlanAdapter(deps: AdapterDependencies): PlanManagerAdapter {
  const { orchestrator } = deps;

  return {
    async enterPlanMode(sessionId: string, skillName: string, blockedTools?: string[]) {
      const effectiveBlockedTools = blockedTools ?? DEFAULT_PLAN_MODE_BLOCKED_TOOLS;

      await orchestrator.planMode.enterPlanMode(sessionId, {
        skillName,
        blockedTools: effectiveBlockedTools,
      });

      return {
        success: true,
        blockedTools: effectiveBlockedTools,
      };
    },

    async exitPlanMode(sessionId: string, reason: 'approved' | 'cancelled', planPath?: string) {
      await orchestrator.planMode.exitPlanMode(sessionId, {
        reason,
        planPath,
      });

      return {
        success: true,
      };
    },

    getPlanModeState(sessionId: string) {
      const isActive = orchestrator.planMode.isInPlanMode(sessionId);
      const blockedTools = orchestrator.planMode.getBlockedTools(sessionId);

      // Get skill name from SessionContext if active
      const active = orchestrator.getActiveSession(sessionId);
      const skillName = active?.sessionContext.getPlanModeState().skillName;

      return {
        isActive,
        skillName,
        blockedTools,
      };
    },
  };
}
