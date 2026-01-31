/**
 * @fileoverview Tests for HookEventHandler
 *
 * TDD: Tests for hook event persistence to the event store.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  HookEventHandler,
  createHookEventHandler,
  type HookEventHandlerDeps,
  type InternalHookTriggeredEvent,
  type InternalHookCompletedEvent,
} from '../hook-event-handler.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): HookEventHandlerDeps {
  return {
    getActiveSession: vi.fn(),
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
  };
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
    it('should persist hook.triggered event for active session', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['builtin:pre-tool-use'],
        hookEvent: 'PreToolUse',
      };

      handler.handleHookTriggered(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.triggered',
        expect.objectContaining({
          hookNames: ['builtin:pre-tool-use'],
          hookEvent: 'PreToolUse',
        }),
        undefined
      );
    });

    it('should skip persistence when session not found', () => {
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(undefined);

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'unknown-session',
        timestamp: new Date().toISOString(),
        hookNames: ['test-hook'],
        hookEvent: 'PreToolUse',
      };

      handler.handleHookTriggered(event);

      expect(deps.appendEventLinearized).not.toHaveBeenCalled();
    });

    it('should include tool context for PreToolUse hooks', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['security-check'],
        hookEvent: 'PreToolUse',
        toolName: 'Bash',
        toolCallId: 'call_123',
      };

      handler.handleHookTriggered(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.triggered',
        expect.objectContaining({
          toolName: 'Bash',
          toolCallId: 'call_123',
        }),
        undefined
      );
    });

    it('should include tool context for PostToolUse hooks', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['audit-hook'],
        hookEvent: 'PostToolUse',
        toolName: 'Read',
        toolCallId: 'call_456',
      };

      handler.handleHookTriggered(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.triggered',
        expect.objectContaining({
          hookEvent: 'PostToolUse',
          toolName: 'Read',
          toolCallId: 'call_456',
        }),
        undefined
      );
    });

    it('should handle multiple hook names', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookTriggeredEvent = {
        type: 'hook_triggered',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['hook-1', 'hook-2', 'hook-3'],
        hookEvent: 'SessionStart',
      };

      handler.handleHookTriggered(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.triggered',
        expect.objectContaining({
          hookNames: ['hook-1', 'hook-2', 'hook-3'],
        }),
        undefined
      );
    });
  });

  describe('handleHookCompleted', () => {
    it('should persist hook.completed with result and duration', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['builtin:pre-tool-use'],
        hookEvent: 'PreToolUse',
        result: 'continue',
        duration: 42,
      };

      handler.handleHookCompleted(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.completed',
        expect.objectContaining({
          hookNames: ['builtin:pre-tool-use'],
          hookEvent: 'PreToolUse',
          result: 'continue',
          duration: 42,
        }),
        undefined
      );
    });

    it('should persist block result with reason', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['security-check'],
        hookEvent: 'PreToolUse',
        result: 'block',
        reason: 'Dangerous command detected',
        duration: 15,
      };

      handler.handleHookCompleted(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.completed',
        expect.objectContaining({
          result: 'block',
          reason: 'Dangerous command detected',
        }),
        undefined
      );
    });

    it('should persist modify result', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['path-transformer'],
        hookEvent: 'PreToolUse',
        result: 'modify',
        duration: 5,
      };

      handler.handleHookCompleted(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.completed',
        expect.objectContaining({
          result: 'modify',
        }),
        undefined
      );
    });

    it('should skip persistence when session not found', () => {
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(undefined);

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'unknown-session',
        timestamp: new Date().toISOString(),
        hookNames: ['test-hook'],
        hookEvent: 'PreToolUse',
        result: 'continue',
      };

      handler.handleHookCompleted(event);

      expect(deps.appendEventLinearized).not.toHaveBeenCalled();
    });

    it('should include tool context for tool-related hooks', () => {
      const session = createMockActiveSession();
      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(session);

      const event: InternalHookCompletedEvent = {
        type: 'hook_completed',
        sessionId: 'test-session',
        timestamp: new Date().toISOString(),
        hookNames: ['audit-hook'],
        hookEvent: 'PostToolUse',
        result: 'continue',
        toolName: 'Write',
        toolCallId: 'call_789',
      };

      handler.handleHookCompleted(event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        'test-session',
        'hook.completed',
        expect.objectContaining({
          toolName: 'Write',
          toolCallId: 'call_789',
        }),
        undefined
      );
    });
  });

  describe('factory function', () => {
    it('should create HookEventHandler instance', () => {
      const handler = createHookEventHandler(deps);
      expect(handler).toBeInstanceOf(HookEventHandler);
    });
  });
});
