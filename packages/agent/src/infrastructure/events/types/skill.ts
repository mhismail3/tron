/**
 * @fileoverview Skill Events
 *
 * Events for skill context changes (adding/removing skills from session).
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Skill Event Payload Types
// =============================================================================

/** Source of the skill (global or project) */
export type SkillSource = 'global' | 'project';

/** How a skill was added to context */
export type SkillAddMethod = 'mention' | 'explicit';

/** How a skill was removed from context */
export type SkillRemoveReason = 'manual' | 'clear' | 'compact';

/**
 * Payload for skill.added event
 */
export interface SkillAddedPayload {
  /** Name of the skill that was added */
  skillName: string;
  /** Source of the skill (global or project) */
  source: SkillSource;
  /** How the skill was added (via @mention or explicit sheet selection) */
  addedVia: SkillAddMethod;
}

/**
 * Payload for skill.removed event
 */
export interface SkillRemovedPayload {
  /** Name of the skill that was removed */
  skillName: string;
  /** Why the skill was removed */
  removedVia: SkillRemoveReason;
}

// =============================================================================
// Skill Events
// =============================================================================

/**
 * Skill added event - emitted when a skill is added to session context
 */
export interface SkillAddedEvent extends BaseEvent {
  type: 'skill.added';
  payload: SkillAddedPayload;
}

/**
 * Skill removed event - emitted when a skill is removed from session context
 */
export interface SkillRemovedEvent extends BaseEvent {
  type: 'skill.removed';
  payload: SkillRemovedPayload;
}
