/**
 * @fileoverview SessionReconstructor - Session State Reconstruction
 *
 * Reconstructs session state from event history. Used when resuming a session
 * to restore in-memory state that isn't directly stored in the database.
 *
 * ## What Gets Reconstructed
 *
 * - **Plan Mode**: Active/inactive, blocked tools
 * - **Interrupt Status**: Whether last assistant message was interrupted
 * - **Current Turn**: Latest turn number from events
 * - **Reasoning Level**: From config.reasoning_level events
 *
 * ## What Uses Existing Trackers
 *
 * - Skills: Use `SkillTracker.fromEvents()` from @tron/core
 * - Rules: Use `RulesTracker.fromEvents()` from @tron/core
 *
 * ## Reset Points
 *
 * Certain events reset state:
 * - `compact.boundary`: Resets plan mode, turn count (but not config)
 * - `context.cleared`: Resets plan mode, turn count
 *
 * ## Usage
 *
 * ```typescript
 * const reconstructor = createSessionReconstructor();
 * const events = await eventStore.getAncestors(session.headEventId);
 * const state = reconstructor.reconstruct(events);
 *
 * // Use with existing trackers
 * const skillTracker = SkillTracker.fromEvents(events);
 * const rulesTracker = RulesTracker.fromEvents(events);
 * ```
 */
import { createLogger } from '@infrastructure/logging/index.js';
import type { SessionEvent as TronSessionEvent } from '@infrastructure/events/types.js';
import { PlanModeHandler, type PlanModeState } from '../handlers/plan-mode.js';

const logger = createLogger('session-reconstructor');

// =============================================================================
// Types
// =============================================================================

export interface ReconstructedState {
  /** Current turn number */
  currentTurn: number;
  /** Whether the session was interrupted */
  wasInterrupted: boolean;
  /** Plan mode state */
  planMode: PlanModeState;
  /** Reasoning level (for extended thinking models) */
  reasoningLevel?: string;
}

// =============================================================================
// SessionReconstructor Class
// =============================================================================

/**
 * Reconstructs session state from event history.
 */
export class SessionReconstructor {
  private planModeHandler: PlanModeHandler;

  constructor() {
    this.planModeHandler = new PlanModeHandler();
  }

  /**
   * Reconstruct session state from events.
   *
   * @param events - Events from getAncestors(), ordered from root to head
   * @returns Reconstructed state
   */
  reconstruct(events: TronSessionEvent[]): ReconstructedState {
    // Track state as we process events
    let currentTurn = 0;
    let reasoningLevel: string | undefined;
    let lastAssistantInterrupted = false;

    // Process events in order (root to head)
    for (const event of events) {
      // Handle reset points first
      if (event.type === 'compact.boundary' || event.type === 'context.cleared') {
        // Reset content-related state
        currentTurn = 0;
        this.planModeHandler.setState({
          isActive: false,
          blockedTools: [],
        });
        // Note: reasoningLevel persists through compaction (it's config, not content)
        continue;
      }

      // Track turn number
      if (event.type === 'stream.turn_start') {
        const payload = event.payload as { turn?: number };
        if (payload.turn !== undefined) {
          currentTurn = payload.turn;
        }
      }

      // Track turn from message.assistant if no stream events
      if (event.type === 'message.assistant') {
        const payload = event.payload as {
          turn?: number;
          interrupted?: boolean;
        };
        if (payload.turn !== undefined && currentTurn < payload.turn) {
          currentTurn = payload.turn;
        }
        // Track interrupt status (will be overwritten by later messages)
        lastAssistantInterrupted = payload.interrupted === true;
      }

      // Track reasoning level
      if (event.type === 'config.reasoning_level') {
        const payload = event.payload as { newLevel?: string };
        reasoningLevel = payload.newLevel;
      }

      // Plan mode is handled by the handler
      if (
        event.type === 'plan.mode_entered' ||
        event.type === 'plan.mode_exited'
      ) {
        // Process single event through handler
        this.planModeHandler.reconstructFromEvents([event]);
      }
    }

    // Get final plan mode state
    const planMode = this.planModeHandler.getState();

    const state: ReconstructedState = {
      currentTurn,
      wasInterrupted: lastAssistantInterrupted,
      planMode,
      reasoningLevel,
    };

    logger.debug('Session state reconstructed', {
      currentTurn: state.currentTurn,
      wasInterrupted: state.wasInterrupted,
      planModeActive: state.planMode.isActive,
      reasoningLevel: state.reasoningLevel,
    });

    return state;
  }

  /**
   * Check if an event is a reset point (compaction or context clear).
   */
  isResetEvent(event: TronSessionEvent): boolean {
    return (
      event.type === 'compact.boundary' || event.type === 'context.cleared'
    );
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a SessionReconstructor instance.
 */
export function createSessionReconstructor(): SessionReconstructor {
  return new SessionReconstructor();
}
