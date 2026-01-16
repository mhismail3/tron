/**
 * @fileoverview PlanModeHandler - Plan Mode State Management
 *
 * Manages plan mode state for a session. Plan mode is entered when
 * the agent uses EnterPlanMode tool and exited when ExitPlanMode is used.
 *
 * While in plan mode, certain tools are blocked until the user approves the plan.
 *
 * ## Usage
 *
 * ```typescript
 * const planMode = createPlanModeHandler();
 *
 * // Enter plan mode
 * planMode.enter('implementation-plan', ['Edit', 'Write', 'Bash']);
 *
 * // Check if a tool is blocked
 * if (planMode.isToolBlocked('Edit')) {
 *   return { error: 'Tool blocked in plan mode' };
 * }
 *
 * // Exit plan mode
 * planMode.exit();
 *
 * // Reconstruct from events (on session resume)
 * planMode.reconstructFromEvents(events);
 * ```
 */
import { createLogger, type TronSessionEvent } from '@tron/core';

const logger = createLogger('plan-mode-handler');

// =============================================================================
// Types
// =============================================================================

export interface PlanModeState {
  isActive: boolean;
  skillName?: string;
  blockedTools: string[];
}

// =============================================================================
// PlanModeHandler Class
// =============================================================================

/**
 * Manages plan mode state for a session.
 *
 * Each session should have its own PlanModeHandler instance.
 */
export class PlanModeHandler {
  private state: PlanModeState = {
    isActive: false,
    blockedTools: [],
  };

  // ===========================================================================
  // State Queries
  // ===========================================================================

  /**
   * Check if plan mode is currently active.
   */
  isActive(): boolean {
    return this.state.isActive;
  }

  /**
   * Get the list of blocked tools.
   */
  getBlockedTools(): string[] {
    return [...this.state.blockedTools];
  }

  /**
   * Get the full plan mode state.
   */
  getState(): PlanModeState {
    return {
      isActive: this.state.isActive,
      skillName: this.state.skillName,
      blockedTools: [...this.state.blockedTools],
    };
  }

  /**
   * Check if a specific tool is blocked.
   *
   * Returns false if not in plan mode, even if the tool would be blocked.
   */
  isToolBlocked(toolName: string): boolean {
    if (!this.state.isActive) {
      return false;
    }
    return this.state.blockedTools.includes(toolName);
  }

  // ===========================================================================
  // State Mutations
  // ===========================================================================

  /**
   * Enter plan mode.
   *
   * @param skillName - Name of the skill that entered plan mode
   * @param blockedTools - List of tools to block until plan is approved
   * @throws Error if already in plan mode
   */
  enter(skillName: string, blockedTools: string[]): void {
    if (this.state.isActive) {
      throw new Error('Already in plan mode');
    }

    this.state = {
      isActive: true,
      skillName,
      blockedTools: [...blockedTools],
    };

    logger.debug('Plan mode entered', {
      skillName,
      blockedToolCount: blockedTools.length,
    });
  }

  /**
   * Exit plan mode.
   *
   * @throws Error if not in plan mode
   */
  exit(): void {
    if (!this.state.isActive) {
      throw new Error('Not in plan mode');
    }

    const previousSkill = this.state.skillName;

    this.state = {
      isActive: false,
      skillName: undefined,
      blockedTools: [],
    };

    logger.debug('Plan mode exited', { previousSkill });
  }

  /**
   * Set state directly (for reconstruction or testing).
   */
  setState(state: PlanModeState): void {
    this.state = {
      isActive: state.isActive,
      skillName: state.skillName,
      blockedTools: [...state.blockedTools],
    };
  }

  // ===========================================================================
  // Reconstruction
  // ===========================================================================

  /**
   * Reconstruct plan mode state from event history.
   *
   * Processes events to determine if plan mode is active and what tools
   * are blocked. Used when resuming a session.
   */
  reconstructFromEvents(events: TronSessionEvent[]): void {
    let isActive = false;
    let skillName: string | undefined;
    let blockedTools: string[] = [];

    for (const event of events) {
      if (event.type === 'plan.mode_entered') {
        const payload = event.payload as {
          skillName?: string;
          blockedTools?: string[];
        };
        isActive = true;
        skillName = payload.skillName;
        blockedTools = payload.blockedTools ?? [];
      } else if (event.type === 'plan.mode_exited') {
        isActive = false;
        skillName = undefined;
        blockedTools = [];
      }
    }

    this.state = {
      isActive,
      skillName,
      blockedTools,
    };

    if (isActive) {
      logger.debug('Plan mode reconstructed', {
        skillName,
        blockedToolCount: blockedTools.length,
      });
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a PlanModeHandler instance.
 */
export function createPlanModeHandler(): PlanModeHandler {
  return new PlanModeHandler();
}
