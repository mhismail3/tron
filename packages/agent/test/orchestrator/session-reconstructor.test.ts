/**
 * @fileoverview SessionReconstructor Unit Tests
 *
 * Tests for session state reconstruction from events.
 *
 * Contract:
 * 1. Reconstruct plan mode state from plan.mode_entered/exited events
 * 2. Determine wasInterrupted from last message.assistant
 * 3. Determine currentTurn from stream.turn_start events
 * 4. Get reasoningLevel from config.reasoning_level events
 * 5. Coordinate with SkillTracker and RulesTracker for full state
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  SessionReconstructor,
  createSessionReconstructor,
  type ReconstructedState,
} from '../../src/orchestrator/session-reconstructor.js';

describe('SessionReconstructor', () => {
  let reconstructor: SessionReconstructor;

  beforeEach(() => {
    reconstructor = createSessionReconstructor();
  });

  describe('Empty events', () => {
    it('should return default state for empty events', () => {
      const state = reconstructor.reconstruct([]);

      expect(state.currentTurn).toBe(0);
      expect(state.wasInterrupted).toBe(false);
      expect(state.planMode.isActive).toBe(false);
      expect(state.planMode.blockedTools).toEqual([]);
      expect(state.reasoningLevel).toBeUndefined();
    });
  });

  describe('Plan mode reconstruction', () => {
    it('should reconstruct active plan mode', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: {
            skillName: 'implementation-plan',
            blockedTools: ['Edit', 'Write', 'Bash'],
          },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.planMode.isActive).toBe(true);
      expect(state.planMode.skillName).toBe('implementation-plan');
      expect(state.planMode.blockedTools).toEqual(['Edit', 'Write', 'Bash']);
    });

    it('should reconstruct inactive plan mode after exit', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: {
            skillName: 'plan',
            blockedTools: ['Edit'],
          },
        },
        {
          id: 'evt_2',
          type: 'plan.mode_exited',
          payload: { approved: true },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.planMode.isActive).toBe(false);
      expect(state.planMode.blockedTools).toEqual([]);
    });
  });

  describe('Interrupt detection', () => {
    it('should detect interrupted session from last assistant message', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'message.user',
          payload: { content: 'Hello' },
        },
        {
          id: 'evt_2',
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Working on it...' }],
            interrupted: true,
            stopReason: 'interrupted',
          },
        },
        {
          id: 'evt_3',
          type: 'notification.interrupted',
          payload: { turn: 1 },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.wasInterrupted).toBe(true);
    });

    it('should not detect interrupted if last assistant completed normally', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'message.user',
          payload: { content: 'Hello' },
        },
        {
          id: 'evt_2',
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Here is your answer' }],
            stopReason: 'end_turn',
          },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.wasInterrupted).toBe(false);
    });

    it('should use most recent assistant message for interrupt detection', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'message.assistant',
          payload: { content: [], interrupted: true },
        },
        {
          id: 'evt_2',
          type: 'message.user',
          payload: { content: 'Continue' },
        },
        {
          id: 'evt_3',
          type: 'message.assistant',
          payload: { content: [{ type: 'text', text: 'Done' }], stopReason: 'end_turn' },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      // Last assistant message was not interrupted
      expect(state.wasInterrupted).toBe(false);
    });
  });

  describe('Turn tracking', () => {
    it('should track current turn from stream.turn_start events', () => {
      const events = [
        { id: 'evt_1', type: 'stream.turn_start', payload: { turn: 1 } },
        { id: 'evt_2', type: 'message.assistant', payload: { content: [] } },
        { id: 'evt_3', type: 'stream.turn_end', payload: { turn: 1 } },
        { id: 'evt_4', type: 'message.user', payload: { content: 'More' } },
        { id: 'evt_5', type: 'stream.turn_start', payload: { turn: 2 } },
        { id: 'evt_6', type: 'message.assistant', payload: { content: [] } },
        { id: 'evt_7', type: 'stream.turn_end', payload: { turn: 2 } },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.currentTurn).toBe(2);
    });

    it('should handle turn from message.assistant if no stream events', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'message.assistant',
          payload: { content: [], turn: 3 },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.currentTurn).toBe(3);
    });

    it('should return 0 if no turn information', () => {
      const events = [
        { id: 'evt_1', type: 'message.user', payload: { content: 'Hello' } },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.currentTurn).toBe(0);
    });
  });

  describe('Reasoning level', () => {
    it('should extract reasoning level from config events', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'config.reasoning_level',
          payload: {
            previousLevel: undefined,
            newLevel: 'high',
          },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.reasoningLevel).toBe('high');
    });

    it('should use most recent reasoning level', () => {
      const events = [
        {
          id: 'evt_1',
          type: 'config.reasoning_level',
          payload: { newLevel: 'low' },
        },
        {
          id: 'evt_2',
          type: 'config.reasoning_level',
          payload: { newLevel: 'medium' },
        },
        {
          id: 'evt_3',
          type: 'config.reasoning_level',
          payload: { newLevel: 'high' },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.reasoningLevel).toBe('high');
    });
  });

  describe('Compaction handling', () => {
    it('should reset state after compaction boundary', () => {
      const events = [
        // Pre-compaction state
        {
          id: 'evt_1',
          type: 'plan.mode_entered',
          payload: { skillName: 'old', blockedTools: ['Edit'] },
        },
        { id: 'evt_2', type: 'stream.turn_start', payload: { turn: 5 } },
        {
          id: 'evt_3',
          type: 'config.reasoning_level',
          payload: { newLevel: 'high' },
        },
        // Compaction
        {
          id: 'evt_4',
          type: 'compact.boundary',
          payload: { originalTokens: 100000, compactedTokens: 20000 },
        },
        {
          id: 'evt_5',
          type: 'compact.summary',
          payload: { summary: 'Previous work...' },
        },
        // Post-compaction continues
        { id: 'evt_6', type: 'stream.turn_start', payload: { turn: 1 } },
      ];

      const state = reconstructor.reconstruct(events as any);

      // After compaction, plan mode should be cleared
      expect(state.planMode.isActive).toBe(false);
      // Turn should be from post-compaction
      expect(state.currentTurn).toBe(1);
      // Reasoning level persists through compaction (it's a config, not content)
      expect(state.reasoningLevel).toBe('high');
    });
  });

  describe('Context clear handling', () => {
    it('should reset state after context clear', () => {
      const events = [
        { id: 'evt_1', type: 'stream.turn_start', payload: { turn: 3 } },
        {
          id: 'evt_2',
          type: 'plan.mode_entered',
          payload: { skillName: 'plan', blockedTools: ['Bash'] },
        },
        // Context cleared
        {
          id: 'evt_3',
          type: 'context.cleared',
          payload: { tokensBefore: 50000, tokensAfter: 5000, reason: 'manual' },
        },
      ];

      const state = reconstructor.reconstruct(events as any);

      // Plan mode should be cleared
      expect(state.planMode.isActive).toBe(false);
      // Turn resets
      expect(state.currentTurn).toBe(0);
    });
  });

  describe('Complex scenarios', () => {
    it('should reconstruct state after agentic loop', () => {
      const events = [
        { id: 'evt_1', type: 'message.user', payload: { content: 'Read files' } },
        { id: 'evt_2', type: 'stream.turn_start', payload: { turn: 1 } },
        {
          id: 'evt_3',
          type: 'message.assistant',
          payload: {
            content: [{ type: 'tool_use', id: 'tc_1', name: 'Read', input: {} }],
            turn: 1,
          },
        },
        {
          id: 'evt_4',
          type: 'tool.result',
          payload: { toolCallId: 'tc_1', content: 'file content', isError: false },
        },
        { id: 'evt_5', type: 'stream.turn_end', payload: { turn: 1 } },
        { id: 'evt_6', type: 'stream.turn_start', payload: { turn: 2 } },
        {
          id: 'evt_7',
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Done reading' }],
            turn: 2,
            stopReason: 'end_turn',
          },
        },
        { id: 'evt_8', type: 'stream.turn_end', payload: { turn: 2 } },
      ];

      const state = reconstructor.reconstruct(events as any);

      expect(state.currentTurn).toBe(2);
      expect(state.wasInterrupted).toBe(false);
    });

    it('should reconstruct state after fork', () => {
      // Fork inherits parent history, so events include parent events
      const events = [
        // Parent events
        { id: 'evt_1', type: 'session.start', payload: {} },
        { id: 'evt_2', type: 'message.user', payload: { content: 'Start' } },
        { id: 'evt_3', type: 'stream.turn_start', payload: { turn: 1 } },
        {
          id: 'evt_4',
          type: 'plan.mode_entered',
          payload: { skillName: 'plan', blockedTools: ['Edit'] },
        },
        // Fork point - forked session continues from here
        { id: 'evt_5', type: 'session.start', payload: {} }, // Fork creates new session.start
        { id: 'evt_6', type: 'message.user', payload: { content: 'Continue differently' } },
      ];

      const state = reconstructor.reconstruct(events as any);

      // Should inherit plan mode from parent
      expect(state.planMode.isActive).toBe(true);
      expect(state.planMode.blockedTools).toEqual(['Edit']);
    });
  });
});
