/**
 * @fileoverview Tests for LifecycleEventHandler
 *
 * LifecycleEventHandler uses EventContext for automatic metadata injection.
 * It handles agent lifecycle events: start, end, interrupted, and api_retry.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  LifecycleEventHandler,
  createLifecycleEventHandler,
  type LifecycleEventHandlerDeps,
} from '../lifecycle-event-handler.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockUIRenderHandler() {
  return {
    handleToolStart: vi.fn(),
    handleToolEnd: vi.fn(),
    handleToolCallDelta: vi.fn(),
    cleanup: vi.fn(),
  };
}

function createMockDeps(): LifecycleEventHandlerDeps {
  return {
    defaultProvider: 'anthropic',
    uiRenderHandler: createMockUIRenderHandler() as unknown as LifecycleEventHandlerDeps['uiRenderHandler'],
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      onAgentStart: vi.fn(),
      onAgentEnd: vi.fn(),
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

describe('LifecycleEventHandler', () => {
  let deps: LifecycleEventHandlerDeps;
  let handler: LifecycleEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createLifecycleEventHandler(deps);
  });

  describe('handleAgentStart', () => {
    it('should call onAgentStart on session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });

      handler.handleAgentStart(ctx);

      expect(mockActive.sessionContext!.onAgentStart).toHaveBeenCalled();
    });

    it('should emit agent.turn_start event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });

      handler.handleAgentStart(ctx);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.turn_start',
        data: {},
      });
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session

      handler.handleAgentStart(ctx);

      // Should still emit event
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.turn_start');
    });
  });

  describe('handleAgentEnd', () => {
    it('should call onAgentEnd on session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });

      handler.handleAgentEnd(ctx);

      expect(mockActive.sessionContext!.onAgentEnd).toHaveBeenCalled();
    });

    it('should cleanup UI render handler', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });

      handler.handleAgentEnd(ctx);

      expect(deps.uiRenderHandler.cleanup).toHaveBeenCalled();
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session

      handler.handleAgentEnd(ctx);

      // Should still cleanup UI render handler
      expect(deps.uiRenderHandler.cleanup).toHaveBeenCalled();
    });

    it('should not emit agent.complete (emitted elsewhere)', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });

      handler.handleAgentEnd(ctx);

      // agent.complete is emitted in runAgent() AFTER all events are persisted
      expect(ctx.emitCalls).toHaveLength(0);
    });
  });

  describe('handleAgentReady', () => {
    it('should emit agent.ready event via context', () => {
      const ctx = createTestContext();

      handler.handleAgentReady(ctx);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.ready',
        data: {},
      });
    });
  });

  describe('handleAgentInterrupted', () => {
    it('should emit agent.complete with interrupted status via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'agent_interrupted',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        turn: 1,
        partialContent: 'partial text',
      } as const;

      handler.handleAgentInterrupted(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.complete',
        data: {
          success: false,
          interrupted: true,
          partialContent: 'partial text',
        },
      });
    });

    it('should handle missing partialContent', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'agent_interrupted',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        turn: 1,
      } as const;

      handler.handleAgentInterrupted(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.complete',
        data: {
          success: false,
          interrupted: true,
          partialContent: undefined,
        },
      });
    });
  });

  describe('handleApiRetry', () => {
    it('should persist enriched error.provider event with category and suggestion', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'api_retry',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        attempt: 1,
        maxRetries: 3,
        errorMessage: 'Rate limit exceeded',
        errorCategory: 'rate_limit',
        delayMs: 5000,
      } as const;

      handler.handleApiRetry(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'error.provider',
        payload: {
          provider: 'anthropic',
          error: 'Rate limit exceeded',
          code: 'rate_limit',
          category: 'rate_limit',
          suggestion: 'Wait a moment and try again',
          retryable: true,
          retryAfter: 5000,
          runId: 'run-123',
        },
      });
    });

    it('should not emit to WebSocket (terminal error handles that)', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'api_retry',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        attempt: 1,
        maxRetries: 1,
        errorMessage: 'Rate limit exceeded',
        errorCategory: 'rate_limit',
        delayMs: 5000,
      } as const;

      handler.handleApiRetry(ctx, event);

      expect(ctx.emitCalls).toHaveLength(0);
    });

    it('should handle missing error details', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'api_retry',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        attempt: 1,
        maxRetries: 3,
        delayMs: 0,
        errorCategory: '',
        errorMessage: '',
      } as const;

      handler.handleApiRetry(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'error.provider',
        payload: {
          provider: 'anthropic',
          error: '',
          code: '',
          category: 'unknown',
          suggestion: undefined,
          retryable: true,
          retryAfter: 0,
          runId: undefined,
        },
      });

      // Should not emit — terminal error handles WebSocket notification
      expect(ctx.emitCalls).toHaveLength(0);
    });
  });

  describe('factory function', () => {
    it('should create LifecycleEventHandler instance', () => {
      const handler = createLifecycleEventHandler(deps);
      expect(handler).toBeInstanceOf(LifecycleEventHandler);
    });
  });
});
