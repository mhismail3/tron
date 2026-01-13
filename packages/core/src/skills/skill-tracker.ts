/**
 * @fileoverview Skill Tracker
 *
 * Manages tracking of skills explicitly added to a session's context.
 * Supports event-sourced reconstruction for session resume/fork/rewind.
 */

import type {
  SkillSource,
  SkillAddMethod,
  AddedSkillInfo,
  SkillAddedPayload,
  SkillRemovedPayload,
} from './types.js';

/**
 * Internal tracking info for an added skill
 */
interface TrackedSkill {
  eventId: string;
  source: SkillSource;
  addedVia: SkillAddMethod;
}

/**
 * Generic event structure for reconstruction
 */
export interface SkillTrackingEvent {
  id: string;
  type: string;
  payload: Record<string, unknown>;
}

/**
 * SkillTracker manages tracking of skills added to a session's context.
 *
 * Key features:
 * - Tracks which skills have been explicitly added (via @mention or explicit selection)
 * - Supports event-sourced reconstruction from event history
 * - Handles context clear/compact (which clear all skills)
 * - Provides AddedSkillInfo[] for context snapshot responses
 */
export class SkillTracker {
  private addedSkills: Map<string, TrackedSkill> = new Map();

  /**
   * Record that a skill has been added to context
   */
  addSkill(
    skillName: string,
    source: SkillSource,
    addedVia: SkillAddMethod,
    eventId: string
  ): void {
    this.addedSkills.set(skillName, { eventId, source, addedVia });
  }

  /**
   * Record that a skill has been removed from context
   * @returns true if the skill was removed, false if it wasn't present
   */
  removeSkill(skillName: string): boolean {
    return this.addedSkills.delete(skillName);
  }

  /**
   * Check if a skill is currently added to context
   */
  hasSkill(skillName: string): boolean {
    return this.addedSkills.has(skillName);
  }

  /**
   * Get all added skills as AddedSkillInfo array
   */
  getAddedSkills(): AddedSkillInfo[] {
    return Array.from(this.addedSkills.entries()).map(([name, info]) => ({
      name,
      source: info.source,
      addedVia: info.addedVia,
      eventId: info.eventId,
    }));
  }

  /**
   * Get the number of added skills
   */
  get count(): number {
    return this.addedSkills.size;
  }

  /**
   * Clear all added skills (for context clear/compact)
   */
  clear(): void {
    this.addedSkills.clear();
  }

  /**
   * Reconstruct skill state from event history.
   *
   * This is the key method for supporting:
   * - Session resume: Replay events to rebuild state
   * - Fork: Events include parent ancestry, state is inherited
   * - Rewind: Only events up to HEAD are included, state reflects that point
   *
   * @param events - Array of events in chronological order
   * @returns New SkillTracker with reconstructed state
   */
  static fromEvents(events: SkillTrackingEvent[]): SkillTracker {
    const tracker = new SkillTracker();

    for (const event of events) {
      switch (event.type) {
        case 'skill.added': {
          const payload = event.payload as unknown as SkillAddedPayload;
          tracker.addSkill(
            payload.skillName,
            payload.source,
            payload.addedVia,
            event.id
          );
          break;
        }
        case 'skill.removed': {
          const payload = event.payload as unknown as SkillRemovedPayload;
          tracker.removeSkill(payload.skillName);
          break;
        }
        case 'context.cleared':
        case 'compact.boundary':
          // Both clear and compact reset skill state
          tracker.clear();
          break;
        // Other event types are ignored
      }
    }

    return tracker;
  }
}

/**
 * Create a new empty SkillTracker
 */
export function createSkillTracker(): SkillTracker {
  return new SkillTracker();
}
