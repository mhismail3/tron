/**
 * @fileoverview Plan Mode Events
 *
 * Events for plan mode lifecycle.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Plan Mode Events
// =============================================================================

/**
 * Plan mode entered event - marks when plan mode is activated
 * Plan mode blocks write operations until plan is approved
 */
export interface PlanModeEnteredEvent extends BaseEvent {
  type: 'plan.mode_entered';
  payload: {
    /** Skill that triggered plan mode */
    skillName: string;
    /** Tools blocked during plan mode (typically Write, Edit, Bash) */
    blockedTools: string[];
  };
}

/**
 * Plan mode exited event - marks when plan mode ends
 */
export interface PlanModeExitedEvent extends BaseEvent {
  type: 'plan.mode_exited';
  payload: {
    /** Reason plan mode ended */
    reason: 'approved' | 'cancelled' | 'timeout';
    /** Path to approved plan file (only present when approved) */
    planPath?: string;
  };
}

/**
 * Plan created event - marks when a plan file is written
 */
export interface PlanCreatedEvent extends BaseEvent {
  type: 'plan.created';
  payload: {
    /** Absolute path to the plan file */
    planPath: string;
    /** Human-readable title of the plan */
    title: string;
    /** SHA-256 hash of plan content */
    contentHash: string;
    /** Estimated token count of the plan */
    tokens?: number;
  };
}
