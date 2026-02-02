/**
 * @fileoverview Plan domain - Plan mode operations
 *
 * Handles plan mode entry, exit, and state queries.
 */

// Re-export handler factory
export { createPlanHandlers } from '@interface/rpc/handlers/plan.handler.js';

// Re-export types
export type {
  PlanEnterParams,
  PlanEnterResult,
  PlanExitParams,
  PlanExitResult,
  PlanGetStateParams,
  PlanGetStateResult,
} from '@interface/rpc/types/plan-mode.js';
