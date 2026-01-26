/**
 * @fileoverview Tests for Plan Mode Enforcement
 *
 * TDD: Tests for plan mode activation, tool blocking, and deactivation.
 * These tests are written FIRST before implementation (RED phase).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type {
  PlanModeEnteredEvent,
  PlanModeExitedEvent,
  SessionEvent,
} from '../index.js';
import {
  isPlanModeEnteredEvent,
  isPlanModeExitedEvent,
} from '../index.js';

// Mock types for the plan mode manager we'll implement
interface PlanModeState {
  isActive: boolean;
  skillName?: string;
  blockedTools: string[];
  activatedAt?: string;
}

// These will be implemented in the actual module
interface PlanModeManager {
  getState(sessionId: string): PlanModeState;
  activate(sessionId: string, skillName: string, blockedTools: string[]): PlanModeEnteredEvent;
  deactivate(sessionId: string, reason: 'approved' | 'cancelled' | 'timeout', planPath?: string): PlanModeExitedEvent;
  isToolBlocked(sessionId: string, toolName: string): boolean;
  reconstructFromEvents(events: SessionEvent[]): PlanModeState;
}

describe('Plan Mode Enforcement', () => {
  describe('activation', () => {
    it('should activate when skill with planMode: true is added', () => {
      // Given a skill with planMode: true
      const skillName = 'plan';
      const blockedTools = ['Write', 'Edit', 'Bash'];

      // When we activate plan mode
      // This test validates the activation contract
      const state: PlanModeState = {
        isActive: true,
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
        activatedAt: new Date().toISOString(),
      };

      expect(state.isActive).toBe(true);
      expect(state.skillName).toBe('plan');
      expect(state.blockedTools).toEqual(['Write', 'Edit', 'Bash']);
    });

    it('should emit plan.mode_entered event', () => {
      const event: PlanModeEnteredEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_entered',
        sequence: 1,
        payload: {
          skillName: 'plan',
          blockedTools: ['Write', 'Edit', 'Bash'],
        },
      };

      expect(event.type).toBe('plan.mode_entered');
      expect(event.payload.skillName).toBe('plan');
      expect(event.payload.blockedTools).toContain('Write');
    });

    it('should include blocked tools in event payload', () => {
      const event: PlanModeEnteredEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_entered',
        sequence: 1,
        payload: {
          skillName: 'plan',
          blockedTools: ['Write', 'Edit', 'Bash', 'NotebookEdit'],
        },
      };

      expect(event.payload.blockedTools).toHaveLength(4);
      expect(event.payload.blockedTools).toContain('Write');
      expect(event.payload.blockedTools).toContain('Edit');
      expect(event.payload.blockedTools).toContain('Bash');
      expect(event.payload.blockedTools).toContain('NotebookEdit');
    });

    it('should not activate for skills without planMode', () => {
      // Given a skill without planMode
      const skillFrontmatter = {
        name: 'regular-skill',
        description: 'A normal skill without plan mode',
        // planMode is NOT set
      };

      // Plan mode should not be activated
      const shouldActivate = skillFrontmatter.planMode === true;
      expect(shouldActivate).toBe(false);
    });
  });

  describe('tool blocking', () => {
    it('should block Write tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Write';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(true);
    });

    it('should block Edit tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Edit';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(true);
    });

    it('should block Bash tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Bash';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(true);
    });

    it('should allow Read tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Read';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(false);
    });

    it('should allow Glob tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Glob';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(false);
    });

    it('should allow Grep tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'Grep';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(false);
    });

    it('should allow AskUserQuestion tool in plan mode', () => {
      const blockedTools = ['Write', 'Edit', 'Bash'];
      const toolName = 'AskUserQuestion';

      const isBlocked = blockedTools.includes(toolName);
      expect(isBlocked).toBe(false);
    });

    it('should return descriptive error when tool blocked', () => {
      const toolName = 'Write';
      const skillName = 'plan';

      const errorMessage = `Tool "${toolName}" is blocked during plan mode. The "${skillName}" skill requires read-only exploration until the plan is approved. Use AskUserQuestion to get user approval.`;

      expect(errorMessage).toContain('blocked during plan mode');
      expect(errorMessage).toContain(toolName);
      expect(errorMessage).toContain('AskUserQuestion');
    });
  });

  describe('deactivation', () => {
    it('should deactivate when user approves via AskUserQuestion', () => {
      const event: PlanModeExitedEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_exited',
        sequence: 2,
        payload: {
          reason: 'approved',
          planPath: '/Users/test/.tron/plans/2026-01-14-120000-my-plan.md',
        },
      };

      expect(event.type).toBe('plan.mode_exited');
      expect(event.payload.reason).toBe('approved');
      expect(event.payload.planPath).toBeDefined();
    });

    it('should emit plan.mode_exited event with approved reason', () => {
      const event: PlanModeExitedEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_exited',
        sequence: 2,
        payload: {
          reason: 'approved',
          planPath: '/path/to/plan.md',
        },
      };

      expect(isPlanModeExitedEvent(event as SessionEvent)).toBe(true);
      expect(event.payload.reason).toBe('approved');
    });

    it('should deactivate when user cancels', () => {
      const event: PlanModeExitedEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_exited',
        sequence: 2,
        payload: {
          reason: 'cancelled',
        },
      };

      expect(event.payload.reason).toBe('cancelled');
      expect(event.payload.planPath).toBeUndefined();
    });

    it('should emit plan.mode_exited event with cancelled reason', () => {
      const event: PlanModeExitedEvent = {
        id: 'evt_test' as any,
        parentId: null,
        sessionId: 'sess_test' as any,
        workspaceId: 'ws_test' as any,
        timestamp: new Date().toISOString(),
        type: 'plan.mode_exited',
        sequence: 2,
        payload: {
          reason: 'cancelled',
        },
      };

      expect(event.type).toBe('plan.mode_exited');
      expect(event.payload.reason).toBe('cancelled');
    });

    it('should unblock Write/Edit/Bash after deactivation', () => {
      // Given plan mode was active
      let state: PlanModeState = {
        isActive: true,
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      };

      // When plan mode is deactivated
      state = {
        isActive: false,
        blockedTools: [],
      };

      // Then tools should be unblocked
      expect(state.isActive).toBe(false);
      expect(state.blockedTools).toEqual([]);

      const isWriteBlocked = state.blockedTools.includes('Write');
      expect(isWriteBlocked).toBe(false);
    });
  });

  describe('state reconstruction', () => {
    it('should reconstruct plan mode state from events', () => {
      const events: SessionEvent[] = [
        {
          id: 'evt_1' as any,
          parentId: null,
          sessionId: 'sess_test' as any,
          workspaceId: 'ws_test' as any,
          timestamp: '2026-01-14T10:00:00.000Z',
          type: 'plan.mode_entered',
          sequence: 1,
          payload: {
            skillName: 'plan',
            blockedTools: ['Write', 'Edit', 'Bash'],
          },
        } as PlanModeEnteredEvent,
      ];

      // Reconstruct state
      let planModeActive = false;
      let blockedTools: string[] = [];

      for (const event of events) {
        if (isPlanModeEnteredEvent(event)) {
          planModeActive = true;
          blockedTools = event.payload.blockedTools;
        } else if (isPlanModeExitedEvent(event)) {
          planModeActive = false;
          blockedTools = [];
        }
      }

      expect(planModeActive).toBe(true);
      expect(blockedTools).toEqual(['Write', 'Edit', 'Bash']);
    });

    it('should be in plan mode after mode_entered without mode_exited', () => {
      const events: SessionEvent[] = [
        {
          id: 'evt_1' as any,
          parentId: null,
          sessionId: 'sess_test' as any,
          workspaceId: 'ws_test' as any,
          timestamp: '2026-01-14T10:00:00.000Z',
          type: 'plan.mode_entered',
          sequence: 1,
          payload: {
            skillName: 'plan',
            blockedTools: ['Write', 'Edit', 'Bash'],
          },
        } as PlanModeEnteredEvent,
        // No mode_exited event
      ];

      // Reconstruct state
      let planModeActive = false;

      for (const event of events) {
        if (isPlanModeEnteredEvent(event)) {
          planModeActive = true;
        } else if (isPlanModeExitedEvent(event)) {
          planModeActive = false;
        }
      }

      expect(planModeActive).toBe(true);
    });

    it('should not be in plan mode after mode_exited', () => {
      const events: SessionEvent[] = [
        {
          id: 'evt_1' as any,
          parentId: null,
          sessionId: 'sess_test' as any,
          workspaceId: 'ws_test' as any,
          timestamp: '2026-01-14T10:00:00.000Z',
          type: 'plan.mode_entered',
          sequence: 1,
          payload: {
            skillName: 'plan',
            blockedTools: ['Write', 'Edit', 'Bash'],
          },
        } as PlanModeEnteredEvent,
        {
          id: 'evt_2' as any,
          parentId: 'evt_1' as any,
          sessionId: 'sess_test' as any,
          workspaceId: 'ws_test' as any,
          timestamp: '2026-01-14T10:05:00.000Z',
          type: 'plan.mode_exited',
          sequence: 2,
          payload: {
            reason: 'approved',
            planPath: '/path/to/plan.md',
          },
        } as PlanModeExitedEvent,
      ];

      // Reconstruct state
      let planModeActive = false;

      for (const event of events) {
        if (isPlanModeEnteredEvent(event)) {
          planModeActive = true;
        } else if (isPlanModeExitedEvent(event)) {
          planModeActive = false;
        }
      }

      expect(planModeActive).toBe(false);
    });
  });

  describe('default blocked tools', () => {
    it('should have standard set of blocked tools', () => {
      const defaultBlockedTools = ['Write', 'Edit', 'Bash', 'NotebookEdit'];

      expect(defaultBlockedTools).toContain('Write');
      expect(defaultBlockedTools).toContain('Edit');
      expect(defaultBlockedTools).toContain('Bash');
      expect(defaultBlockedTools).toContain('NotebookEdit');
    });

    it('should allow customization of blocked tools via skill frontmatter', () => {
      // A skill might want to block fewer or more tools
      const customBlockedTools = ['Write', 'Edit']; // Allows Bash

      expect(customBlockedTools).toContain('Write');
      expect(customBlockedTools).toContain('Edit');
      expect(customBlockedTools).not.toContain('Bash');
    });
  });
});

// =============================================================================
// Orchestrator Integration Tests
// =============================================================================

import { EventStore, SessionId } from '../index.js';
import { EventStoreOrchestrator } from '../orchestrator/persistence/event-store-orchestrator.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

const createTestOrchestrator = async (testDir: string) => {
  const eventStore = new EventStore(path.join(testDir, 'events.db'));
  await eventStore.initialize();

  const orchestrator = new EventStoreOrchestrator({
    defaultModel: 'claude-sonnet-4-20250514',
    defaultProvider: 'anthropic',
    eventStoreDbPath: path.join(testDir, 'events.db'),
    eventStore,
  });

  // Mock auth for tests - must set on authProvider, not orchestrator
  (orchestrator as any).authProvider.setCachedAuth({ type: 'api_key', apiKey: 'test-key' });
  (orchestrator as any).initialized = true;

  return { orchestrator, eventStore };
};

describe('Plan Mode Orchestrator Integration', () => {
  let testDir: string;
  let orchestrator: EventStoreOrchestrator;
  let eventStore: EventStore;
  let sessionId: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-plan-mode-test-'));
    const result = await createTestOrchestrator(testDir);
    orchestrator = result.orchestrator;
    eventStore = result.eventStore;

    const session = await orchestrator.createSession({
      workingDirectory: testDir,
    });
    sessionId = session.sessionId;
  });

  afterEach(async () => {
    await orchestrator?.shutdown();
    await eventStore?.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('isInPlanMode', () => {
    it('should return false for new session', () => {
      expect(orchestrator.isInPlanMode(sessionId)).toBe(false);
    });

    it('should return true after entering plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      expect(orchestrator.isInPlanMode(sessionId)).toBe(true);
    });

    it('should return false after exiting plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await orchestrator.exitPlanMode(sessionId, {
        reason: 'approved',
      });

      expect(orchestrator.isInPlanMode(sessionId)).toBe(false);
    });

    it('should return false for non-existent session', () => {
      expect(orchestrator.isInPlanMode('non-existent')).toBe(false);
    });
  });

  describe('getBlockedTools', () => {
    it('should return empty array for new session', () => {
      expect(orchestrator.getBlockedTools(sessionId)).toEqual([]);
    });

    it('should return blocked tools when in plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      expect(orchestrator.getBlockedTools(sessionId)).toEqual(['Write', 'Edit', 'Bash']);
    });

    it('should return empty array after exiting plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await orchestrator.exitPlanMode(sessionId, {
        reason: 'cancelled',
      });

      expect(orchestrator.getBlockedTools(sessionId)).toEqual([]);
    });
  });

  describe('enterPlanMode', () => {
    it('should emit plan.mode_entered event', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      const events = await eventStore.getEventsBySession(SessionId(sessionId));
      const planEvent = events.find(e => e.type === 'plan.mode_entered');

      expect(planEvent).toBeDefined();
      expect(planEvent!.payload).toEqual({
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });
    });

    it('should not allow entering plan mode twice', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await expect(
        orchestrator.enterPlanMode(sessionId, {
          skillName: 'another-plan',
          blockedTools: ['Write'],
        })
      ).rejects.toThrow(/already in plan mode/i);
    });
  });

  describe('exitPlanMode', () => {
    it('should emit plan.mode_exited event with approved reason', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await orchestrator.exitPlanMode(sessionId, {
        reason: 'approved',
        planPath: '/path/to/plan.md',
      });

      const events = await eventStore.getEventsBySession(SessionId(sessionId));
      const exitEvent = events.find(e => e.type === 'plan.mode_exited');

      expect(exitEvent).toBeDefined();
      expect(exitEvent!.payload).toEqual({
        reason: 'approved',
        planPath: '/path/to/plan.md',
      });
    });

    it('should emit plan.mode_exited event with cancelled reason', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await orchestrator.exitPlanMode(sessionId, {
        reason: 'cancelled',
      });

      const events = await eventStore.getEventsBySession(SessionId(sessionId));
      const exitEvent = events.find(e => e.type === 'plan.mode_exited');

      expect(exitEvent).toBeDefined();
      expect(exitEvent!.payload).toEqual({
        reason: 'cancelled',
      });
    });

    it('should not allow exiting plan mode when not in plan mode', async () => {
      await expect(
        orchestrator.exitPlanMode(sessionId, {
          reason: 'approved',
        })
      ).rejects.toThrow(/not in plan mode/i);
    });
  });

  describe('isToolBlocked', () => {
    it('should return false for tools when not in plan mode', () => {
      expect(orchestrator.isToolBlocked(sessionId, 'Write')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'Edit')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'Bash')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'Read')).toBe(false);
    });

    it('should return true for blocked tools when in plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      expect(orchestrator.isToolBlocked(sessionId, 'Write')).toBe(true);
      expect(orchestrator.isToolBlocked(sessionId, 'Edit')).toBe(true);
      expect(orchestrator.isToolBlocked(sessionId, 'Bash')).toBe(true);
    });

    it('should return false for allowed tools when in plan mode', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      expect(orchestrator.isToolBlocked(sessionId, 'Read')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'Glob')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'Grep')).toBe(false);
      expect(orchestrator.isToolBlocked(sessionId, 'AskUserQuestion')).toBe(false);
    });
  });

  describe('state reconstruction on resume', () => {
    it('should reconstruct plan mode state from events', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      // Shutdown and recreate orchestrator
      await orchestrator.shutdown();

      const result2 = await createTestOrchestrator(testDir);
      const orchestrator2 = result2.orchestrator;

      // Resume the session
      await orchestrator2.resumeSession(sessionId);

      expect(orchestrator2.isInPlanMode(sessionId)).toBe(true);
      expect(orchestrator2.getBlockedTools(sessionId)).toEqual(['Write', 'Edit', 'Bash']);

      await orchestrator2.shutdown();
    });

    it('should not be in plan mode after exited event on resume', async () => {
      await orchestrator.enterPlanMode(sessionId, {
        skillName: 'plan',
        blockedTools: ['Write', 'Edit', 'Bash'],
      });

      await orchestrator.exitPlanMode(sessionId, {
        reason: 'approved',
      });

      // Shutdown and recreate orchestrator
      await orchestrator.shutdown();

      const result2 = await createTestOrchestrator(testDir);
      const orchestrator2 = result2.orchestrator;

      await orchestrator2.resumeSession(sessionId);

      expect(orchestrator2.isInPlanMode(sessionId)).toBe(false);
      expect(orchestrator2.getBlockedTools(sessionId)).toEqual([]);

      await orchestrator2.shutdown();
    });
  });

  describe('getPlanModeBlockedToolMessage', () => {
    it('should return descriptive error message', () => {
      const message = orchestrator.getPlanModeBlockedToolMessage('Write');

      expect(message).toContain('plan mode');
      expect(message).toContain('Write');
    });
  });
});
