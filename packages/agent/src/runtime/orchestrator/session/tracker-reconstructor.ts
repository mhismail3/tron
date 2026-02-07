/**
 * @fileoverview TrackerReconstructor
 *
 * Reconstructs all session trackers from event history.
 * Extracted from SessionManager.resumeSession for modularity and testability.
 *
 * ## Responsibilities
 *
 * - Reconstruct SkillTracker from skill events
 * - Reconstruct RulesTracker from rules events
 * - Reconstruct SubAgentTracker from subagent events
 * - Reconstruct TodoTracker from todo events
 * - Extract API token count from last turn_end event
 *
 * ## Usage
 *
 * ```typescript
 * const reconstructor = createTrackerReconstructor();
 * const events = await eventStore.getAncestors(session.headEventId);
 * const trackers = reconstructor.reconstruct(events);
 *
 * // Use reconstructed trackers
 * const activeSession = {
 *   skillTracker: trackers.skillTracker,
 *   rulesTracker: trackers.rulesTracker,
 *   subagentTracker: trackers.subagentTracker,
 *   todoTracker: trackers.todoTracker,
 * };
 *
 * // Restore API token count
 * if (trackers.apiTokenCount !== undefined) {
 *   agent.getContextManager().setApiContextTokens(trackers.apiTokenCount);
 * }
 * ```
 */
import { createLogger } from '@infrastructure/logging/index.js';
import { SkillTracker, type SkillTrackingEvent } from '@capabilities/extensions/skills/skill-tracker.js';
import { RulesTracker, type RulesTrackingEvent } from '@context/rules-tracker.js';
import { SubAgentTracker, type SubagentTrackingEvent } from '@capabilities/tools/subagent/subagent-tracker.js';
import { TodoTracker } from '@capabilities/todos/todo-tracker.js';
import type { TodoTrackingEvent } from '@capabilities/todos/types.js';
import type { SessionEvent } from '@infrastructure/events/types.js';

const logger = createLogger('tracker-reconstructor');

// =============================================================================
// Types
// =============================================================================

/**
 * Result of tracker reconstruction.
 */
export interface ReconstructedTrackers {
  /** Reconstructed skill tracker */
  skillTracker: SkillTracker;
  /** Reconstructed rules tracker */
  rulesTracker: RulesTracker;
  /** Reconstructed subagent tracker */
  subagentTracker: SubAgentTracker;
  /** Reconstructed todo tracker */
  todoTracker: TodoTracker;
  /** API token count from last turn_end event (undefined if no turn_end events) */
  apiTokenCount?: number;
}

// =============================================================================
// TrackerReconstructor Class
// =============================================================================

/**
 * Reconstructs all session trackers from event history.
 *
 * Each tracker type has its own static `fromEvents` method that handles
 * the reconstruction logic. This class orchestrates calling all of them
 * and extracting additional data like API token count.
 */
export class TrackerReconstructor {
  /**
   * Reconstruct all trackers from event history.
   *
   * @param events - Events from getAncestors(), ordered from root to head
   * @returns Reconstructed trackers and API token count
   */
  reconstruct(events: SessionEvent[]): ReconstructedTrackers {
    // Reconstruct each tracker using its static fromEvents method
    const skillTracker = SkillTracker.fromEvents(events as SkillTrackingEvent[]);
    const rulesTracker = RulesTracker.fromEvents(events as RulesTrackingEvent[]);
    const subagentTracker = SubAgentTracker.fromEvents(events as SubagentTrackingEvent[]);
    const todoTracker = TodoTracker.fromEvents(events as TodoTrackingEvent[]);

    // Extract API token count from last turn_end event
    const apiTokenCount = this.extractApiTokenCount(events);

    // Log reconstruction summary
    logger.debug('Trackers reconstructed from events', {
      skillCount: skillTracker.count,
      rulesFiles: rulesTracker.getTotalFiles(),
      subagentCount: subagentTracker.count,
      activeSubagents: subagentTracker.activeCount,
      todoCount: todoTracker.count,
      hasApiTokenCount: apiTokenCount !== undefined,
    });

    return {
      skillTracker,
      rulesTracker,
      subagentTracker,
      todoTracker,
      apiTokenCount,
    };
  }

  /**
   * Extract the best available token count from event history.
   *
   * Scans backwards for either `stream.turn_end` or `compact.boundary`,
   * whichever is more recent. After compaction, the last turn_end's count
   * is stale — the compact.boundary's estimatedContextTokens reflects
   * the actual post-compaction context size.
   */
  private extractApiTokenCount(events: SessionEvent[]): number | undefined {
    for (let i = events.length - 1; i >= 0; i--) {
      const event = events[i];

      if (event?.type === 'stream.turn_end') {
        const payload = event.payload as {
          tokenRecord?: { computed?: { contextWindowTokens?: number } };
        };
        if (payload?.tokenRecord?.computed?.contextWindowTokens !== undefined) {
          return payload.tokenRecord.computed.contextWindowTokens;
        }
      }

      if (event?.type === 'compact.boundary') {
        const payload = event.payload as {
          estimatedContextTokens?: number;
          compactedTokens?: number;
        };
        // Prefer estimatedContextTokens (total context); fall back to compactedTokens (backward compat)
        return payload?.estimatedContextTokens ?? payload?.compactedTokens;
      }
    }
    return undefined;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a TrackerReconstructor instance.
 */
export function createTrackerReconstructor(): TrackerReconstructor {
  return new TrackerReconstructor();
}
