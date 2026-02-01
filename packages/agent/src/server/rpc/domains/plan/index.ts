/**
 * @fileoverview Plan domain - Plan mode operations
 *
 * Handles plan mode entry, exit, and state queries.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handlePlanEnter,
  handlePlanExit,
  handlePlanGetState,
  createPlanHandlers,
} from '../../../../rpc/handlers/plan.handler.js';

// Re-export types
export type {
  PlanEnterParams,
  PlanEnterResult,
  PlanExitParams,
  PlanExitResult,
  PlanGetStateParams,
  PlanGetStateResult,
} from '../../../../rpc/types/plan-mode.js';
