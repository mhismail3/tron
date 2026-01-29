/**
 * @fileoverview Turn Events
 *
 * Events for turn-level failures and errors.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Turn Events
// =============================================================================

/**
 * Turn failed event
 *
 * Emitted when a turn fails due to provider errors, context limits,
 * or other recoverable/non-recoverable errors. This event ensures
 * the iOS app receives visibility into failures.
 */
export interface TurnFailedEvent extends BaseEvent {
  type: 'turn.failed';
  payload: {
    /** Turn number that failed */
    turn: number;
    /** Human-readable error message */
    error: string;
    /** Error category code (e.g., 'PAUTH', 'PRATE', 'NET', 'CTX') */
    code?: string;
    /** Human-readable error category */
    category?: string;
    /** Whether the user can retry this operation */
    recoverable: boolean;
    /** Any content generated before the failure occurred */
    partialContent?: string;
  };
}
