/**
 * @fileoverview Skill Tracking Tests (TDD)
 *
 * Tests written FIRST to define expected behavior for tracking
 * skills explicitly added to session context.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  SkillTracker,
  type SkillTrackingEvent,
  type AddedSkillInfo,
} from '../index.js';

// =============================================================================
// SkillTracker Unit Tests
// =============================================================================

describe('SkillTracker', () => {
  let tracker: SkillTracker;

  beforeEach(() => {
    tracker = new SkillTracker();
  });

  describe('addSkill', () => {
    it('adds a skill to tracking', () => {
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');

      expect(tracker.hasSkill('my-skill')).toBe(true);
      expect(tracker.getAddedSkills()).toHaveLength(1);
    });

    it('tracks skill source correctly', () => {
      tracker.addSkill('global-skill', 'global', 'mention', 'event-1');
      tracker.addSkill('project-skill', 'project', 'explicit', 'event-2');

      const skills = tracker.getAddedSkills();
      expect(skills.find(s => s.name === 'global-skill')?.source).toBe('global');
      expect(skills.find(s => s.name === 'project-skill')?.source).toBe('project');
    });

    it('tracks addedVia correctly', () => {
      tracker.addSkill('mentioned', 'global', 'mention', 'event-1');
      tracker.addSkill('explicit', 'global', 'explicit', 'event-2');

      const skills = tracker.getAddedSkills();
      expect(skills.find(s => s.name === 'mentioned')?.addedVia).toBe('mention');
      expect(skills.find(s => s.name === 'explicit')?.addedVia).toBe('explicit');
    });

    it('does not duplicate skill on re-add', () => {
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');
      tracker.addSkill('my-skill', 'global', 'mention', 'event-2');

      expect(tracker.getAddedSkills()).toHaveLength(1);
      // Should keep the latest event ID
      expect(tracker.getAddedSkills()[0].eventId).toBe('event-2');
    });

    it('tracks eventId for removal support', () => {
      tracker.addSkill('my-skill', 'global', 'mention', 'event-123');

      const skills = tracker.getAddedSkills();
      expect(skills[0].eventId).toBe('event-123');
    });
  });

  describe('removeSkill', () => {
    it('removes a skill from tracking', () => {
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');

      const removed = tracker.removeSkill('my-skill');

      expect(removed).toBe(true);
      expect(tracker.hasSkill('my-skill')).toBe(false);
      expect(tracker.getAddedSkills()).toHaveLength(0);
    });

    it('returns false for non-existent skill', () => {
      const removed = tracker.removeSkill('non-existent');

      expect(removed).toBe(false);
    });

    it('only removes specified skill', () => {
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.addSkill('skill-b', 'global', 'mention', 'event-2');
      tracker.addSkill('skill-c', 'global', 'mention', 'event-3');

      tracker.removeSkill('skill-b');

      expect(tracker.hasSkill('skill-a')).toBe(true);
      expect(tracker.hasSkill('skill-b')).toBe(false);
      expect(tracker.hasSkill('skill-c')).toBe(true);
      expect(tracker.getAddedSkills()).toHaveLength(2);
    });

    it('tracks removed skill in removedSkillNames', () => {
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');
      tracker.removeSkill('my-skill');

      expect(tracker.getRemovedSkillNames()).toContain('my-skill');
    });
  });

  describe('getRemovedSkillNames', () => {
    it('returns empty array for new tracker', () => {
      expect(tracker.getRemovedSkillNames()).toEqual([]);
    });

    it('returns skill names that were removed', () => {
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.addSkill('skill-b', 'global', 'mention', 'event-2');
      tracker.removeSkill('skill-a');

      expect(tracker.getRemovedSkillNames()).toEqual(['skill-a']);
    });

    it('clears skill from removedSkillNames when re-added', () => {
      // Add then remove a skill
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');
      tracker.removeSkill('my-skill');

      // Verify it's in removed list
      expect(tracker.getRemovedSkillNames()).toContain('my-skill');

      // Re-add the skill
      tracker.addSkill('my-skill', 'global', 'mention', 'event-2');

      // Should no longer be in removed list
      expect(tracker.getRemovedSkillNames()).not.toContain('my-skill');
      expect(tracker.hasSkill('my-skill')).toBe(true);
    });

    it('handles multiple add/remove/re-add cycles', () => {
      // First cycle: add -> remove
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.removeSkill('skill-a');
      expect(tracker.getRemovedSkillNames()).toContain('skill-a');

      // Second cycle: re-add -> remove again
      tracker.addSkill('skill-a', 'global', 'mention', 'event-2');
      expect(tracker.getRemovedSkillNames()).not.toContain('skill-a');
      tracker.removeSkill('skill-a');
      expect(tracker.getRemovedSkillNames()).toContain('skill-a');

      // Third cycle: re-add
      tracker.addSkill('skill-a', 'global', 'mention', 'event-3');
      expect(tracker.getRemovedSkillNames()).not.toContain('skill-a');
      expect(tracker.hasSkill('skill-a')).toBe(true);
    });
  });

  describe('clear', () => {
    it('removes all skills', () => {
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.addSkill('skill-b', 'project', 'explicit', 'event-2');
      tracker.addSkill('skill-c', 'global', 'mention', 'event-3');

      tracker.clear();

      expect(tracker.getAddedSkills()).toHaveLength(0);
      expect(tracker.hasSkill('skill-a')).toBe(false);
      expect(tracker.hasSkill('skill-b')).toBe(false);
      expect(tracker.hasSkill('skill-c')).toBe(false);
    });

    it('clears removedSkillNames as well', () => {
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.removeSkill('skill-a');

      // Verify skill is in removed list
      expect(tracker.getRemovedSkillNames()).toContain('skill-a');

      tracker.clear();

      // Both added and removed should be cleared
      expect(tracker.getAddedSkills()).toHaveLength(0);
      expect(tracker.getRemovedSkillNames()).toHaveLength(0);
    });
  });

  describe('getAddedSkills', () => {
    it('returns empty array for new tracker', () => {
      expect(tracker.getAddedSkills()).toEqual([]);
    });

    it('returns all added skills with correct structure', () => {
      tracker.addSkill('skill-a', 'global', 'mention', 'event-1');
      tracker.addSkill('skill-b', 'project', 'explicit', 'event-2');

      const skills = tracker.getAddedSkills();

      expect(skills).toHaveLength(2);
      expect(skills).toEqual(expect.arrayContaining([
        { name: 'skill-a', source: 'global', addedVia: 'mention', eventId: 'event-1' },
        { name: 'skill-b', source: 'project', addedVia: 'explicit', eventId: 'event-2' },
      ]));
    });
  });
});

// =============================================================================
// Event Reconstruction Tests
// =============================================================================

describe('SkillTracker.fromEvents', () => {
  it('reconstructs empty state from empty events', () => {
    const tracker = SkillTracker.fromEvents([]);

    expect(tracker.getAddedSkills()).toEqual([]);
  });

  it('reconstructs state from skill.added events', () => {
    const events: MockEvent[] = [
      {
        id: 'event-1',
        type: 'skill.added',
        payload: { skillName: 'my-skill', source: 'global', addedVia: 'mention' },
      },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.hasSkill('my-skill')).toBe(true);
    const skills = tracker.getAddedSkills();
    expect(skills[0]).toEqual({
      name: 'my-skill',
      source: 'global',
      addedVia: 'mention',
      eventId: 'event-1',
    });
  });

  it('handles skill added then removed', () => {
    const events: MockEvent[] = [
      {
        id: 'event-1',
        type: 'skill.added',
        payload: { skillName: 'my-skill', source: 'global', addedVia: 'mention' },
      },
      {
        id: 'event-2',
        type: 'skill.removed',
        payload: { skillName: 'my-skill', removedVia: 'manual' },
      },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.hasSkill('my-skill')).toBe(false);
    expect(tracker.getAddedSkills()).toHaveLength(0);
  });

  it('handles context.cleared event (clears all skills)', () => {
    const events: MockEvent[] = [
      {
        id: 'event-1',
        type: 'skill.added',
        payload: { skillName: 'skill-a', source: 'global', addedVia: 'mention' },
      },
      {
        id: 'event-2',
        type: 'skill.added',
        payload: { skillName: 'skill-b', source: 'project', addedVia: 'explicit' },
      },
      {
        id: 'event-3',
        type: 'context.cleared',
        payload: { tokensBefore: 10000, tokensAfter: 0, reason: 'manual' },
      },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.getAddedSkills()).toHaveLength(0);
  });

  it('handles compact.boundary event (clears all skills)', () => {
    const events: MockEvent[] = [
      {
        id: 'event-1',
        type: 'skill.added',
        payload: { skillName: 'skill-a', source: 'global', addedVia: 'mention' },
      },
      {
        id: 'event-2',
        type: 'compact.boundary',
        payload: { originalTokens: 10000, compactedTokens: 3000, compressionRatio: 0.3 },
      },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.getAddedSkills()).toHaveLength(0);
  });

  it('handles skills added after clear', () => {
    const events: MockEvent[] = [
      {
        id: 'event-1',
        type: 'skill.added',
        payload: { skillName: 'old-skill', source: 'global', addedVia: 'mention' },
      },
      {
        id: 'event-2',
        type: 'context.cleared',
        payload: { tokensBefore: 10000, tokensAfter: 0, reason: 'manual' },
      },
      {
        id: 'event-3',
        type: 'skill.added',
        payload: { skillName: 'new-skill', source: 'project', addedVia: 'explicit' },
      },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.hasSkill('old-skill')).toBe(false);
    expect(tracker.hasSkill('new-skill')).toBe(true);
    expect(tracker.getAddedSkills()).toHaveLength(1);
  });

  it('preserves order of multiple adds/removes', () => {
    const events: MockEvent[] = [
      { id: 'e1', type: 'skill.added', payload: { skillName: 'a', source: 'global', addedVia: 'mention' } },
      { id: 'e2', type: 'skill.added', payload: { skillName: 'b', source: 'global', addedVia: 'mention' } },
      { id: 'e3', type: 'skill.removed', payload: { skillName: 'a', removedVia: 'manual' } },
      { id: 'e4', type: 'skill.added', payload: { skillName: 'c', source: 'project', addedVia: 'explicit' } },
      { id: 'e5', type: 'skill.added', payload: { skillName: 'a', source: 'global', addedVia: 'mention' } },
    ];

    const tracker = SkillTracker.fromEvents(events);

    expect(tracker.getAddedSkills()).toHaveLength(3);
    expect(tracker.hasSkill('a')).toBe(true);
    expect(tracker.hasSkill('b')).toBe(true);
    expect(tracker.hasSkill('c')).toBe(true);
    // 'a' was re-added with e5, should have that event ID
    expect(tracker.getAddedSkills().find(s => s.name === 'a')?.eventId).toBe('e5');
  });
});

// =============================================================================
// Fork Tests (Integration)
// =============================================================================

describe('Skill Tracking - Fork Scenarios', () => {
  it('fork inherits parent skill state via event ancestry', () => {
    // Parent session events
    const parentEvents: MockEvent[] = [
      { id: 'p1', type: 'skill.added', payload: { skillName: 'inherited-skill', source: 'global', addedVia: 'mention' } },
    ];

    // Fork events include parent events via ancestry
    const forkEvents: MockEvent[] = [
      ...parentEvents,
      { id: 'f1', type: 'session.fork', payload: { forkedFrom: 'p1' } },
    ];

    const tracker = SkillTracker.fromEvents(forkEvents);

    expect(tracker.hasSkill('inherited-skill')).toBe(true);
  });

  it('new skill adds in fork do not affect parent', () => {
    const parentEvents: MockEvent[] = [
      { id: 'p1', type: 'skill.added', payload: { skillName: 'parent-skill', source: 'global', addedVia: 'mention' } },
    ];

    const forkEvents: MockEvent[] = [
      ...parentEvents,
      { id: 'f1', type: 'session.fork', payload: { forkedFrom: 'p1' } },
      { id: 'f2', type: 'skill.added', payload: { skillName: 'fork-skill', source: 'project', addedVia: 'explicit' } },
    ];

    const parentTracker = SkillTracker.fromEvents(parentEvents);
    const forkTracker = SkillTracker.fromEvents(forkEvents);

    // Parent should not have fork-only skill
    expect(parentTracker.hasSkill('fork-skill')).toBe(false);
    expect(parentTracker.hasSkill('parent-skill')).toBe(true);

    // Fork should have both
    expect(forkTracker.hasSkill('parent-skill')).toBe(true);
    expect(forkTracker.hasSkill('fork-skill')).toBe(true);
  });
});

// =============================================================================
// Spell Tracking Tests
// =============================================================================

describe('Spell Tracking', () => {
  let tracker: SkillTracker;

  beforeEach(() => {
    tracker = new SkillTracker();
  });

  describe('addUsedSpell', () => {
    it('adds a spell to usedSpellNames set', () => {
      tracker.addUsedSpell('my-spell');

      expect(tracker.getUsedSpellNames()).toContain('my-spell');
    });

    it('is idempotent - adding same spell twice does not duplicate', () => {
      tracker.addUsedSpell('my-spell');
      tracker.addUsedSpell('my-spell');

      expect(tracker.getUsedSpellNames()).toHaveLength(1);
      expect(tracker.getUsedSpellNames()).toContain('my-spell');
    });

    it('tracks multiple different spells', () => {
      tracker.addUsedSpell('spell-a');
      tracker.addUsedSpell('spell-b');
      tracker.addUsedSpell('spell-c');

      const spells = tracker.getUsedSpellNames();
      expect(spells).toHaveLength(3);
      expect(spells).toContain('spell-a');
      expect(spells).toContain('spell-b');
      expect(spells).toContain('spell-c');
    });
  });

  describe('getUsedSpellNames', () => {
    it('returns empty array for new tracker', () => {
      expect(tracker.getUsedSpellNames()).toEqual([]);
    });

    it('returns array of all used spell names', () => {
      tracker.addUsedSpell('spell-a');
      tracker.addUsedSpell('spell-b');

      const spells = tracker.getUsedSpellNames();
      expect(spells).toHaveLength(2);
      expect(spells.sort()).toEqual(['spell-a', 'spell-b']);
    });
  });

  describe('clear clears used spells', () => {
    it('clears usedSpellNames along with other state', () => {
      // Add skills and spells
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');
      tracker.addUsedSpell('my-spell');

      // Verify both are tracked
      expect(tracker.getAddedSkills()).toHaveLength(1);
      expect(tracker.getUsedSpellNames()).toHaveLength(1);

      // Clear
      tracker.clear();

      // Both should be cleared
      expect(tracker.getAddedSkills()).toHaveLength(0);
      expect(tracker.getUsedSpellNames()).toHaveLength(0);
    });
  });

  describe('spells persist across multiple calls (not removed on re-add)', () => {
    it('used spells persist even when same spell is re-used', () => {
      // Use spell in turn 1
      tracker.addUsedSpell('spell-a');
      expect(tracker.getUsedSpellNames()).toContain('spell-a');

      // Re-use spell in turn 3 (simulated by calling addUsedSpell again)
      tracker.addUsedSpell('spell-a');

      // Spell should still be in the set
      expect(tracker.getUsedSpellNames()).toContain('spell-a');
      expect(tracker.getUsedSpellNames()).toHaveLength(1);
    });

    it('spells accumulate over session (never auto-removed)', () => {
      tracker.addUsedSpell('spell-a');
      tracker.addUsedSpell('spell-b');
      tracker.addUsedSpell('spell-a'); // Re-use
      tracker.addUsedSpell('spell-c');

      const spells = tracker.getUsedSpellNames();
      expect(spells).toHaveLength(3);
      expect(spells).toContain('spell-a');
      expect(spells).toContain('spell-b');
      expect(spells).toContain('spell-c');
    });
  });

  describe('spells are independent from skills', () => {
    it('adding a skill does not affect spell tracking', () => {
      tracker.addUsedSpell('my-spell');
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');

      expect(tracker.getUsedSpellNames()).toHaveLength(1);
      expect(tracker.getAddedSkills()).toHaveLength(1);
    });

    it('removing a skill does not affect spell tracking', () => {
      tracker.addUsedSpell('my-spell');
      tracker.addSkill('my-skill', 'global', 'mention', 'event-1');
      tracker.removeSkill('my-skill');

      // Spell should still be tracked
      expect(tracker.getUsedSpellNames()).toHaveLength(1);
      expect(tracker.getUsedSpellNames()).toContain('my-spell');
    });

    it('spell with same name as skill tracks independently', () => {
      // Add both a skill and a spell with the same name
      tracker.addSkill('shared-name', 'global', 'mention', 'event-1');
      tracker.addUsedSpell('shared-name');

      // Both should be tracked independently
      expect(tracker.hasSkill('shared-name')).toBe(true);
      expect(tracker.getUsedSpellNames()).toContain('shared-name');

      // Remove the skill - spell should still be tracked
      tracker.removeSkill('shared-name');
      expect(tracker.hasSkill('shared-name')).toBe(false);
      expect(tracker.getUsedSpellNames()).toContain('shared-name');
    });
  });
});

// =============================================================================
// Detailed Snapshot Tests
// =============================================================================

describe('Skill Tracking - Detailed Snapshot', () => {
  it('returns empty addedSkills for new session', () => {
    const tracker = new SkillTracker();

    expect(tracker.getAddedSkills()).toEqual([]);
  });

  it('returns correct skills after multiple adds/removes', () => {
    const tracker = new SkillTracker();

    tracker.addSkill('a', 'global', 'mention', 'e1');
    tracker.addSkill('b', 'project', 'explicit', 'e2');
    tracker.addSkill('c', 'global', 'mention', 'e3');
    tracker.removeSkill('b');

    const skills = tracker.getAddedSkills();

    expect(skills).toHaveLength(2);
    expect(skills.map(s => s.name).sort()).toEqual(['a', 'c']);
  });
});
