/**
 * @fileoverview Plan Mode Controller
 *
 * Extracted from EventStoreOrchestrator to handle plan mode operations.
 * Plan mode is a read-only exploration state where write tools are blocked
 * until the user approves the plan.
 *
 * ## Responsibilities
 *
 * - Track plan mode state per session
 * - Provide tool blocking checks
 * - Emit plan mode events for UI updates
 * - Persist plan mode transitions as events
 */

import { createLogger } from '../logging/logger.js';
import type { ActiveSession } from './types.js';

const logger = createLogger('plan-mode-controller');

// =============================================================================
// Types
// =============================================================================

export interface PlanModeControllerConfig {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Emit event */
  emit: (event: string, data: unknown) => void;
}

export interface EnterPlanModeOptions {
  skillName: string;
  blockedTools: string[];
}

export interface ExitPlanModeOptions {
  reason: 'approved' | 'cancelled' | 'timeout';
  planPath?: string;
}

// =============================================================================
// PlanModeController Class
// =============================================================================

/**
 * Handles plan mode operations for sessions.
 * Plan mode blocks write tools until the user approves the plan.
 */
export class PlanModeController {
  private config: PlanModeControllerConfig;

  constructor(config: PlanModeControllerConfig) {
    this.config = config;
  }

  /**
   * Check if a session is in plan mode.
   */
  isInPlanMode(sessionId: string): boolean {
    const active = this.config.getActiveSession(sessionId);
    if (!active) return false;
    return active.sessionContext.isInPlanMode();
  }

  /**
   * Get the list of blocked tools for a session.
   */
  getBlockedTools(sessionId: string): string[] {
    const active = this.config.getActiveSession(sessionId);
    if (!active) return [];
    return active.sessionContext.getBlockedTools();
  }

  /**
   * Check if a specific tool is blocked for a session.
   */
  isToolBlocked(sessionId: string, toolName: string): boolean {
    const active = this.config.getActiveSession(sessionId);
    if (!active) return false;
    return active.sessionContext.isToolBlocked(toolName);
  }

  /**
   * Get a descriptive error message for blocked tools.
   */
  getBlockedToolMessage(toolName: string): string {
    return `Tool "${toolName}" is blocked during plan mode. ` +
      `The session is in read-only exploration mode until the plan is approved. ` +
      `Use AskUserQuestion to present your plan and get user approval.`;
  }

  /**
   * Enter plan mode for a session.
   * Records plan.mode_entered event and updates session state.
   */
  async enterPlanMode(sessionId: string, options: EnterPlanModeOptions): Promise<void> {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    if (active.sessionContext.isInPlanMode()) {
      throw new Error(`Session ${sessionId} is already in plan mode`);
    }

    // Append plan.mode_entered event
    const event = await active.sessionContext.appendEvent('plan.mode_entered', {
      skillName: options.skillName,
      blockedTools: options.blockedTools,
    });

    // Update plan mode state
    active.sessionContext.enterPlanMode(options.skillName, options.blockedTools);

    logger.info('Plan mode entered', {
      sessionId,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
      eventId: event?.id,
    });

    this.config.emit('plan.mode_entered', {
      sessionId,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
    });
  }

  /**
   * Exit plan mode for a session.
   * Records plan.mode_exited event and updates session state.
   */
  async exitPlanMode(sessionId: string, options: ExitPlanModeOptions): Promise<void> {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    if (!active.sessionContext.isInPlanMode()) {
      throw new Error(`Session ${sessionId} is not in plan mode`);
    }

    // Build payload (only include planPath if present)
    const payload: Record<string, unknown> = { reason: options.reason };
    if (options.planPath) {
      payload.planPath = options.planPath;
    }

    // Append plan.mode_exited event
    const event = await active.sessionContext.appendEvent('plan.mode_exited', payload);

    // Update plan mode state
    active.sessionContext.exitPlanMode();

    logger.info('Plan mode exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
      eventId: event?.id,
    });

    this.config.emit('plan.mode_exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a PlanModeController instance.
 */
export function createPlanModeController(
  config: PlanModeControllerConfig
): PlanModeController {
  return new PlanModeController(config);
}
