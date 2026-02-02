/**
 * @fileoverview Tests for Plan Mode Events
 *
 * TDD: Tests for plan mode event types, type guards, and validation.
 * These tests are written FIRST before implementation (RED phase).
 */

import { describe, it, expect } from 'vitest';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type PlanModeEnteredEvent,
  type PlanModeExitedEvent,
  type PlanCreatedEvent,
  type SessionEvent,
  isPlanModeEnteredEvent,
  isPlanModeExitedEvent,
  isPlanCreatedEvent,
  isPlanEvent,
} from '../types.js';

// Helper to create a base event for testing
function createBaseEvent(type: string) {
  return {
    id: EventId('evt_test123'),
    parentId: EventId('evt_parent456'),
    sessionId: SessionId('sess_test789'),
    workspaceId: WorkspaceId('ws_test'),
    timestamp: new Date().toISOString(),
    type,
    sequence: 1,
  };
}

describe('Plan Events', () => {
  describe('PlanModeEnteredEvent', () => {
    it('should create valid plan.mode_entered event', () => {
      const event: PlanModeEnteredEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: {
          skillName: 'plan',
          blockedTools: ['Write', 'Edit', 'Bash'],
        },
      };

      expect(event.type).toBe('plan.mode_entered');
      expect(event.payload.skillName).toBe('plan');
      expect(event.payload.blockedTools).toEqual(['Write', 'Edit', 'Bash']);
    });

    it('should include skillName in payload', () => {
      const event: PlanModeEnteredEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: {
          skillName: 'custom-plan-skill',
          blockedTools: ['Write'],
        },
      };

      expect(event.payload.skillName).toBe('custom-plan-skill');
    });

    it('should include blockedTools array', () => {
      const event: PlanModeEnteredEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: {
          skillName: 'plan',
          blockedTools: ['Write', 'Edit', 'Bash', 'WebFetch'],
        },
      };

      expect(event.payload.blockedTools).toHaveLength(4);
      expect(event.payload.blockedTools).toContain('Write');
      expect(event.payload.blockedTools).toContain('Edit');
      expect(event.payload.blockedTools).toContain('Bash');
    });

    it('should allow empty blockedTools array', () => {
      const event: PlanModeEnteredEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: {
          skillName: 'permissive-plan',
          blockedTools: [],
        },
      };

      expect(event.payload.blockedTools).toHaveLength(0);
    });
  });

  describe('PlanModeExitedEvent', () => {
    it('should create valid plan.mode_exited event', () => {
      const event: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: {
          reason: 'approved',
        },
      };

      expect(event.type).toBe('plan.mode_exited');
      expect(event.payload.reason).toBe('approved');
    });

    it('should include reason field', () => {
      const approvedEvent: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: { reason: 'approved' },
      };
      expect(approvedEvent.payload.reason).toBe('approved');

      const cancelledEvent: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: { reason: 'cancelled' },
      };
      expect(cancelledEvent.payload.reason).toBe('cancelled');

      const timeoutEvent: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: { reason: 'timeout' },
      };
      expect(timeoutEvent.payload.reason).toBe('timeout');
    });

    it('should include planPath when approved', () => {
      const event: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: {
          reason: 'approved',
          planPath: '/Users/test/.tron/plans/2026-01-13-120000-my-plan.md',
        },
      };

      expect(event.payload.planPath).toBe('/Users/test/.tron/plans/2026-01-13-120000-my-plan.md');
    });

    it('should not include planPath when cancelled', () => {
      const event: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: {
          reason: 'cancelled',
        },
      };

      expect(event.payload.planPath).toBeUndefined();
    });

    it('should not include planPath when timeout', () => {
      const event: PlanModeExitedEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: {
          reason: 'timeout',
        },
      };

      expect(event.payload.planPath).toBeUndefined();
    });
  });

  describe('PlanCreatedEvent', () => {
    it('should create valid plan.created event', () => {
      const event: PlanCreatedEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/Users/test/.tron/plans/2026-01-13-143022-add-feature.md',
          title: 'Add new authentication feature',
          contentHash: 'sha256:abc123def456',
        },
      };

      expect(event.type).toBe('plan.created');
      expect(event.payload.planPath).toContain('.tron/plans/');
      expect(event.payload.title).toBe('Add new authentication feature');
    });

    it('should require absolute planPath', () => {
      const event: PlanCreatedEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/absolute/path/to/plan.md',
          title: 'Test Plan',
          contentHash: 'sha256:test',
        },
      };

      // Path should be absolute (starts with /)
      expect(event.payload.planPath.startsWith('/')).toBe(true);
    });

    it('should include contentHash', () => {
      const event: PlanCreatedEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/path/to/plan.md',
          title: 'Test',
          contentHash: 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        },
      };

      expect(event.payload.contentHash).toContain('sha256:');
    });

    it('should optionally include token count', () => {
      const eventWithTokens: PlanCreatedEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/path/to/plan.md',
          title: 'Test',
          contentHash: 'sha256:test',
          tokens: 1500,
        },
      };

      expect(eventWithTokens.payload.tokens).toBe(1500);

      const eventWithoutTokens: PlanCreatedEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/path/to/plan.md',
          title: 'Test',
          contentHash: 'sha256:test',
        },
      };

      expect(eventWithoutTokens.payload.tokens).toBeUndefined();
    });
  });

  describe('Type guards', () => {
    it('isPlanModeEnteredEvent returns true for correct type', () => {
      const event: SessionEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: {
          skillName: 'plan',
          blockedTools: ['Write', 'Edit', 'Bash'],
        },
      } as SessionEvent;

      expect(isPlanModeEnteredEvent(event)).toBe(true);
    });

    it('isPlanModeExitedEvent returns true for correct type', () => {
      const event: SessionEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: {
          reason: 'approved',
        },
      } as SessionEvent;

      expect(isPlanModeExitedEvent(event)).toBe(true);
    });

    it('isPlanCreatedEvent returns true for correct type', () => {
      const event: SessionEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: {
          planPath: '/path/to/plan.md',
          title: 'Test',
          contentHash: 'sha256:test',
        },
      } as SessionEvent;

      expect(isPlanCreatedEvent(event)).toBe(true);
    });

    it('returns false for other event types', () => {
      const sessionStartEvent: SessionEvent = {
        ...createBaseEvent('session.start'),
        type: 'session.start',
        payload: {
          workingDirectory: '/test',
          model: 'claude-sonnet-4',
        },
      } as SessionEvent;

      expect(isPlanModeEnteredEvent(sessionStartEvent)).toBe(false);
      expect(isPlanModeExitedEvent(sessionStartEvent)).toBe(false);
      expect(isPlanCreatedEvent(sessionStartEvent)).toBe(false);
    });

    it('isPlanEvent returns true for any plan event type', () => {
      const enteredEvent: SessionEvent = {
        ...createBaseEvent('plan.mode_entered'),
        type: 'plan.mode_entered',
        payload: { skillName: 'plan', blockedTools: [] },
      } as SessionEvent;

      const exitedEvent: SessionEvent = {
        ...createBaseEvent('plan.mode_exited'),
        type: 'plan.mode_exited',
        payload: { reason: 'approved' },
      } as SessionEvent;

      const createdEvent: SessionEvent = {
        ...createBaseEvent('plan.created'),
        type: 'plan.created',
        payload: { planPath: '/test', title: 'Test', contentHash: 'hash' },
      } as SessionEvent;

      expect(isPlanEvent(enteredEvent)).toBe(true);
      expect(isPlanEvent(exitedEvent)).toBe(true);
      expect(isPlanEvent(createdEvent)).toBe(true);
    });

    it('isPlanEvent returns false for non-plan events', () => {
      const toolEvent: SessionEvent = {
        ...createBaseEvent('tool.call'),
        type: 'tool.call',
        payload: {
          toolCallId: 'call_123',
          name: 'Read',
          arguments: {},
          turn: 1,
        },
      } as SessionEvent;

      expect(isPlanEvent(toolEvent)).toBe(false);
    });
  });
});
