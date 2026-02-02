/**
 * @fileoverview Plan Mode RPC Types
 *
 * Types for plan mode methods.
 */

// =============================================================================
// Plan Mode Methods
// =============================================================================

/** Default tools blocked in plan mode */
export const DEFAULT_PLAN_MODE_BLOCKED_TOOLS = ['Write', 'Edit', 'Bash', 'NotebookEdit'];

/** Enter plan mode for a session */
export interface PlanEnterParams {
  /** Session ID */
  sessionId: string;
  /** Name of the skill that triggered plan mode */
  skillName: string;
  /** Tools to block (defaults to Write, Edit, Bash, NotebookEdit) */
  blockedTools?: string[];
}

export interface PlanEnterResult {
  /** Whether plan mode was entered successfully */
  success: boolean;
  /** Tools that are now blocked */
  blockedTools: string[];
}

/** Exit plan mode for a session */
export interface PlanExitParams {
  /** Session ID */
  sessionId: string;
  /** Reason for exiting (approved or cancelled) */
  reason: 'approved' | 'cancelled';
  /** Optional path to the plan file */
  planPath?: string;
}

export interface PlanExitResult {
  /** Whether plan mode was exited successfully */
  success: boolean;
}

/** Get plan mode state for a session */
export interface PlanGetStateParams {
  /** Session ID */
  sessionId: string;
}

export interface PlanGetStateResult {
  /** Whether plan mode is active */
  isActive: boolean;
  /** Name of the skill that triggered plan mode (if active) */
  skillName?: string;
  /** Tools that are blocked (if active) */
  blockedTools: string[];
}
