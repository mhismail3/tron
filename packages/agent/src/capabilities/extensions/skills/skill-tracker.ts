/**
 * @fileoverview Skill Tracker
 *
 * Manages tracking of skills explicitly added to a session's context.
 * Supports event-sourced reconstruction for session resume/fork.
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
   * Skills that were explicitly removed (for "stop following" instruction)
   * These persist until context is cleared/compacted
   */
  private removedSkillNames: Set<string> = new Set();
  /**
   * Spells (ephemeral skills) used in this session.
   * Tracked for "stop following" instruction on subsequent prompts.
   * Unlike skills, spells are not persisted via events - they're injected once and forgotten.
   */
  private usedSpellNames: Set<string> = new Set();

  /**
   * Record that a skill has been added to context.
   * If the skill was previously removed, it's taken off the removed list.
   */
  addSkill(
    skillName: string,
    source: SkillSource,
    addedVia: SkillAddMethod,
    eventId: string
  ): void {
    this.addedSkills.set(skillName, { eventId, source, addedVia });
    // If re-adding a previously removed skill, take it off the removed list
    this.removedSkillNames.delete(skillName);
  }

  /**
   * Record that a skill has been removed from context.
   * The skill is also added to removedSkillNames so the model
   * can be instructed to stop following any @mentions.
   * @returns true if the skill was removed, false if it wasn't present
   */
  removeSkill(skillName: string): boolean {
    const wasPresent = this.addedSkills.delete(skillName);
    // Track as removed so we can tell the model to stop following it
    this.removedSkillNames.add(skillName);
    return wasPresent;
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
   * Get skill names that were explicitly removed.
   * Used to instruct the model to stop following @mentions of these skills.
   */
  getRemovedSkillNames(): string[] {
    return Array.from(this.removedSkillNames);
  }

  /**
   * Record that a spell was used (adds to removal list for subsequent prompts).
   * Spells are ephemeral - they're injected once and then the model is told
   * to stop following them. This method is idempotent (Set handles duplicates).
   */
  addUsedSpell(spellName: string): void {
    this.usedSpellNames.add(spellName);
  }

  /**
   * Get spell names that were used in this session.
   * Used to instruct the model to stop following these spells.
   */
  getUsedSpellNames(): string[] {
    return Array.from(this.usedSpellNames);
  }

  /**
   * Clear all added skills, removed tracking, and used spells (for context clear/compact)
   */
  clear(): void {
    this.addedSkills.clear();
    this.removedSkillNames.clear();
    this.usedSpellNames.clear();
  }

  /**
   * Reconstruct skill state from event history.
   *
   * This is the key method for supporting:
   * - Session resume: Replay events to rebuild state
   * - Fork: Events include parent ancestry, state is inherited
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
