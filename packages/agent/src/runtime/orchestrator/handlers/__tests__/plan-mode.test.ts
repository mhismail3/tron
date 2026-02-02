/**
 * @fileoverview PlanModeHandler Unit Tests
 *
 * Tests for the PlanModeHandler which manages plan mode state.
 * Plan mode blocks certain tools until the user approves a plan.
 *
 * Contract:
 * 1. Track plan mode active/inactive state
 * 2. Track blocked tools list
 * 3. Check if specific tools are blocked
 * 4. Reconstruct state from event history
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  PlanModeHandler,
  createPlanModeHandler,
  type PlanModeState,
} from '../plan-mode.js';

describe('PlanModeHandler', () => {
  let handler: PlanModeHandler;

  beforeEach(() => {
    handler = createPlanModeHandler();
  });

  describe('Initial state', () => {
    it('should start inactive', () => {
      expect(handler.isActive()).toBe(false);
    });

    it('should have no blocked tools initially', () => {
      expect(handler.getBlockedTools()).toEqual([]);
    });

    it('should return initial state correctly', () => {
      const state = handler.getState();
      expect(state).toEqual({
        isActive: false,
        skillName: undefined,
        blockedTools: [],
      });
    });
  });

  describe('enter()', () => {
    it('should activate plan mode', () => {
      handler.enter('test-skill', ['Edit', 'Write', 'Bash']);

      expect(handler.isActive()).toBe(true);
    });

    it('should track skill name', () => {
      handler.enter('my-planning-skill', ['Edit']);

      const state = handler.getState();
      expect(state.skillName).toBe('my-planning-skill');
    });

    it('should track blocked tools', () => {
      handler.enter('skill', ['Edit', 'Write', 'Bash']);

      expect(handler.getBlockedTools()).toEqual(['Edit', 'Write', 'Bash']);
    });

    it('should throw if already in plan mode', () => {
      handler.enter('skill-1', ['Edit']);

      expect(() => handler.enter('skill-2', ['Write'])).toThrow(
        /already in plan mode/i
      );
    });
  });

  describe('exit()', () => {
    it('should deactivate plan mode', () => {
      handler.enter('skill', ['Edit']);
      handler.exit();

      expect(handler.isActive()).toBe(false);
    });

    it('should clear skill name', () => {
      handler.enter('skill', ['Edit']);
      handler.exit();

      const state = handler.getState();
      expect(state.skillName).toBeUndefined();
    });

    it('should clear blocked tools', () => {
      handler.enter('skill', ['Edit', 'Write']);
      handler.exit();

      expect(handler.getBlockedTools()).toEqual([]);
    });

    it('should throw if not in plan mode', () => {
      expect(() => handler.exit()).toThrow(/not in plan mode/i);
    });
  });

  describe('isToolBlocked()', () => {
    it('should return false when not in plan mode', () => {
      expect(handler.isToolBlocked('Edit')).toBe(false);
      expect(handler.isToolBlocked('Write')).toBe(false);
    });

    it('should return true for blocked tools when in plan mode', () => {
      handler.enter('skill', ['Edit', 'Write']);

      expect(handler.isToolBlocked('Edit')).toBe(true);
      expect(handler.isToolBlocked('Write')).toBe(true);
    });

    it('should return false for non-blocked tools when in plan mode', () => {
      handler.enter('skill', ['Edit', 'Write']);

      expect(handler.isToolBlocked('Read')).toBe(false);
      expect(handler.isToolBlocked('Grep')).toBe(false);
    });
  });

  describe('reconstructFromEvents()', () => {
    it('should reconstruct inactive state from empty events', () => {
      handler.reconstructFromEvents([]);

      expect(handler.isActive()).toBe(false);
      expect(handler.getBlockedTools()).toEqual([]);
    });

    it('should reconstruct active state from enter event', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: {
            skillName: 'test-skill',
            blockedTools: ['Edit', 'Write'],
          },
        },
      ];

      handler.reconstructFromEvents(events as any);

      expect(handler.isActive()).toBe(true);
      expect(handler.getState().skillName).toBe('test-skill');
      expect(handler.getBlockedTools()).toEqual(['Edit', 'Write']);
    });

    it('should reconstruct inactive state from enter then exit events', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: {
            skillName: 'skill',
            blockedTools: ['Edit'],
          },
        },
        {
          id: 'evt_2',
          type: 'plan.mode_exited',
          payload: {
            approved: true,
          },
        },
      ];

      handler.reconstructFromEvents(events as any);

      expect(handler.isActive()).toBe(false);
      expect(handler.getBlockedTools()).toEqual([]);
    });

    it('should handle multiple enter/exit cycles', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: { skillName: 'skill-1', blockedTools: ['Edit'] },
        },
        {
          id: 'evt_2',
          type: 'plan.mode_exited',
          payload: { approved: true },
        },
        {
          id: 'evt_3',
          type: 'plan.mode_entered',
          payload: { skillName: 'skill-2', blockedTools: ['Write', 'Bash'] },
        },
      ];

      handler.reconstructFromEvents(events as any);

      expect(handler.isActive()).toBe(true);
      expect(handler.getState().skillName).toBe('skill-2');
      expect(handler.getBlockedTools()).toEqual(['Write', 'Bash']);
    });

    it('should ignore non-plan-mode events', () => {
      const events = [
        { id: 'evt_1', type: 'message.user', payload: {} },
        {
          id: 'evt_2',
          type: 'plan.mode_entered',
          payload: { skillName: 'skill', blockedTools: ['Edit'] },
        },
        { id: 'evt_3', type: 'message.assistant', payload: {} },
      ];

      handler.reconstructFromEvents(events as any);

      expect(handler.isActive()).toBe(true);
      expect(handler.getBlockedTools()).toEqual(['Edit']);
    });
  });

  describe('setState()', () => {
    it('should set state directly', () => {
      const newState: PlanModeState = {
        isActive: true,
        skillName: 'direct-skill',
        blockedTools: ['Bash', 'Write'],
      };

      handler.setState(newState);

      expect(handler.getState()).toEqual(newState);
    });

    it('should allow setting inactive state', () => {
      handler.enter('skill', ['Edit']);

      handler.setState({
        isActive: false,
        blockedTools: [],
      });

      expect(handler.isActive()).toBe(false);
    });
  });
});
