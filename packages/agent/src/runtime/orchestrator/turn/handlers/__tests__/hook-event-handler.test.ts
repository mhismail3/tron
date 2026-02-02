/**
 * @fileoverview Tests for HookEventHandler
 *
 * HookEventHandler uses EventContext for automatic metadata injection.
 * It persists hook lifecycle events (triggered/completed) to the event store.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  HookEventHandler,
  createHookEventHandler,
  type HookEventHandlerDeps,
  type InternalHookTriggeredEvent,
  type InternalHookCompletedEvent,
} from '../hook-event-handler.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): HookEventHandlerDeps {
  return {};
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      getCurrentTurn: vi.fn().mockReturnValue(1),
    } as unknown as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
}

function createTestContext(options: {
  sessionId?: SessionId;
  runId?: string;
  active?: ActiveSession;
} = {}): TestEventContext {
  return createTestEventContext({
    sessionId: options.sessionId ?? ('test-session' as SessionId),
    runId: options.runId,
    active: options.active,
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('HookEventHandler', () => {
  let deps: HookEventHandlerDeps;
  let handler: HookEventHandler;

  beforeEach(() => {
    vi.clearAllMocks();
    deps = createMockDeps();
    handler = createHookEventHandler(deps);
  });

  describe('handleHookTriggered', () => {
    it('should persist hook.triggered event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['builtin:pre-tool-use'],
        hookEvent: 'PreToolUse',
      };

      handler.handleHookTriggered(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'hook.triggered',
        payload: expect.objectContaining({
          hookNames: ['builtin:pre-tool-use'],
          hookEvent: 'PreToolUse',
          runId: 'run-123',
        }),
      });
    });

    it('should skip persistence when no active session', () => {
      const ctx = createTestContext(); // No active session

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'unknown-session',
        timestamp: new Date().toISOString(),
        hookNames: ['test-hook'],
        hookEvent: 'PreToolUse',
      };

      handler.handleHookTriggered(ctx, event);

      expect(ctx.persistCalls).toHaveLength(0);
    });

    it('should include tool context for PreToolUse hooks', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['security-check'],
        hookEvent: 'PreToolUse',
        toolName: 'Bash',
        toolCallId: 'call_123',
      };

      handler.handleHookTriggered(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        toolName: 'Bash',
        toolCallId: 'call_123',
      });
    });

    it('should include tool context for PostToolUse hooks', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['audit-hook'],
        hookEvent: 'PostToolUse',
        toolName: 'Read',
        toolCallId: 'call_456',
      };

      handler.handleHookTriggered(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        hookEvent: 'PostToolUse',
        toolName: 'Read',
        toolCallId: 'call_456',
      });
    });

    it('should handle multiple hook names', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['hook-1', 'hook-2', 'hook-3'],
        hookEvent: 'SessionStart',
      };

      handler.handleHookTriggered(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        hookNames: ['hook-1', 'hook-2', 'hook-3'],
      });
    });
  });

  describe('handleHookCompleted', () => {
    it('should persist hook.completed with result and duration', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['builtin:pre-tool-use'],
        hookEvent: 'PreToolUse',
        result: 'continue',
        duration: 42,
      };

      handler.handleHookCompleted(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'hook.completed',
        payload: expect.objectContaining({
          hookNames: ['builtin:pre-tool-use'],
          hookEvent: 'PreToolUse',
          result: 'continue',
          duration: 42,
          runId: 'run-123',
        }),
      });
    });

    it('should persist block result with reason', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['security-check'],
        hookEvent: 'PreToolUse',
        result: 'block',
        reason: 'Dangerous command detected',
        duration: 15,
      };

      handler.handleHookCompleted(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        result: 'block',
        reason: 'Dangerous command detected',
      });
    });

    it('should persist modify result', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['path-transformer'],
        hookEvent: 'PreToolUse',
        result: 'modify',
        duration: 5,
      };

      handler.handleHookCompleted(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        result: 'modify',
      });
    });

    it('should skip persistence when no active session', () => {
      const ctx = createTestContext(); // No active session

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'unknown-session',
        timestamp: new Date().toISOString(),
        hookNames: ['test-hook'],
        hookEvent: 'PreToolUse',
        result: 'continue',
      };

      handler.handleHookCompleted(ctx, event);

      expect(ctx.persistCalls).toHaveLength(0);
    });

    it('should include tool context for tool-related hooks', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      const ctx = createTestContext({ active: mockActive });

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        hookNames: ['audit-hook'],
        hookEvent: 'PostToolUse',
        result: 'continue',
        toolName: 'Write',
        toolCallId: 'call_789',
      };

      handler.handleHookCompleted(ctx, event);

      expect(ctx.persistCalls[0].payload).toMatchObject({
        toolName: 'Write',
        toolCallId: 'call_789',
      });
    });
  });

  describe('factory function', () => {
    it('should create HookEventHandler instance', () => {
      const handler = createHookEventHandler(deps);
      expect(handler).toBeInstanceOf(HookEventHandler);
    });
  });
});
