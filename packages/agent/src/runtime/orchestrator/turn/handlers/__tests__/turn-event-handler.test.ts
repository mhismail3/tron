/**
 * @fileoverview Tests for TurnEventHandler
 *
 * TurnEventHandler uses EventContext for automatic metadata injection.
 * It handles turn lifecycle: turn_start, turn_end, response_complete.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { TurnEventHandler, createTurnEventHandler, type TurnEventHandlerDeps } from '../turn-event-handler.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';
import type { TronEvent } from '../../../../types/index.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): TurnEventHandlerDeps {
  return {};
}

function createMockTokenRecord(overrides: Partial<{
  contextWindowTokens: number;
  newInputTokens: number;
  outputTokens: number;
}> = {}) {
  return {
    source: {
      provider: 'anthropic' as const,
      timestamp: new Date().toISOString(),
      rawInputTokens: 100,
      rawOutputTokens: overrides.outputTokens ?? 50,
      rawCacheReadTokens: 0,
      rawCacheCreationTokens: 0,
      rawCacheCreation5mTokens: 0,
      rawCacheCreation1hTokens: 0,
    },
    computed: {
      contextWindowTokens: overrides.contextWindowTokens ?? 1000,
      newInputTokens: overrides.newInputTokens ?? 100,
      previousContextBaseline: 0,
      calculationMethod: 'anthropic_cache_aware' as const,
    },
    meta: {
      turn: 1,
      sessionId: 'test-session',
      extractedAt: new Date().toISOString(),
      normalizedAt: new Date().toISOString(),
    },
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {
      getContextManager: vi.fn().mockReturnValue({
        setApiContextTokens: vi.fn(),
      }),
    } as unknown as ActiveSession['agent'],
    sessionContext: {
      startTurn: vi.fn(),
      endTurn: vi.fn().mockReturnValue({
        turn: 1,
        content: [],
        tokenRecord: createMockTokenRecord(),
      }),
      hasPreToolContentFlushed: vi.fn().mockReturnValue(false),
      getTurnStartTime: vi.fn().mockReturnValue(Date.now() - 1000),
      setResponseTokenUsage: vi.fn(),
      getLastTokenRecord: vi.fn().mockReturnValue(createMockTokenRecord()),
      addMessageEventId: vi.fn(),
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

describe('TurnEventHandler', () => {
  let deps: TurnEventHandlerDeps;
  let handler: TurnEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createTurnEventHandler(deps);
  });

  describe('handleTurnStart', () => {
    it('should emit agent.turn_start event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'turn_start', turn: 1 } as unknown as TronEvent;

      handler.handleTurnStart(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.turn_start',
        data: { turn: 1 },
      });
    });

    it('should persist stream.turn_start event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'turn_start', turn: 1 } as unknown as TronEvent;

      handler.handleTurnStart(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'stream.turn_start',
        payload: { turn: 1, runId: 'run-456' },
      });
    });

    it('should call startTurn on session context when active session exists', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'turn_start', turn: 2 } as unknown as TronEvent;

      handler.handleTurnStart(ctx, event);

      expect(mockActive.sessionContext!.startTurn).toHaveBeenCalledWith(2);
    });

    it('should not call startTurn when turn is undefined', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'turn_start' } as unknown as TronEvent;

      handler.handleTurnStart(ctx, event);

      expect(mockActive.sessionContext!.startTurn).not.toHaveBeenCalled();
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = { type: 'turn_start', turn: 1 } as unknown as TronEvent;

      handler.handleTurnStart(ctx, event);

      // Should still emit and persist
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.persistCalls).toHaveLength(1);
    });
  });

  describe('handleTurnEnd', () => {
    it('should emit agent.turn_end event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'turn_end',
        turn: 1,
        duration: 1000,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.turn_end');
      expect(ctx.emitCalls[0].data).toMatchObject({
        turn: 1,
        duration: 1000,
      });
    });

    it('should persist stream.turn_end event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      // Find the stream.turn_end persist call
      const turnEndCall = ctx.persistCalls.find(c => c.type === 'stream.turn_end');
      expect(turnEndCall).toBeDefined();
      expect(turnEndCall!.payload).toMatchObject({
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
        runId: 'run-456',
      });
    });

    it('should create message.assistant when content exists and not pre-flushed', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      // Mock endTurn to return content
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [{ type: 'text', text: 'Hello world' }],
        tokenRecord: createMockTokenRecord(),
      });

      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      // Should have message.assistant and stream.turn_end persist calls
      expect(ctx.persistCalls).toHaveLength(2);
      const messageCall = ctx.persistCalls.find(c => c.type === 'message.assistant');
      expect(messageCall).toBeDefined();
      expect(messageCall!.payload).toMatchObject({
        turn: 1,
        stopReason: 'end_turn',
        runId: 'run-789',
      });
    });

    it('should skip message.assistant when content was pre-flushed for tools', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      // Mark as pre-flushed (tools were called)
      (mockActive.sessionContext!.hasPreToolContentFlushed as ReturnType<typeof vi.fn>).mockReturnValue(true);
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [{ type: 'text', text: 'Hello world' }],
        tokenRecord: createMockTokenRecord(),
      });

      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      // Should only have stream.turn_end persist call
      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0].type).toBe('stream.turn_end');
    });

    it('should sync context tokens to ContextManager', () => {
      const mockSetApiContextTokens = vi.fn();
      const mockActive = createMockActiveSession({ currentRunId: 'run-111' });
      (mockActive.agent.getContextManager as ReturnType<typeof vi.fn>).mockReturnValue({
        setApiContextTokens: mockSetApiContextTokens,
      });
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [],
        tokenRecord: createMockTokenRecord({ contextWindowTokens: 5000 }),
      });

      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      expect(mockSetApiContextTokens).toHaveBeenCalledWith(5000);
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      handler.handleTurnEnd(ctx, event);

      // Should still emit and persist stream.turn_end
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.persistCalls).toHaveLength(1);
    });
  });

  describe('handleResponseComplete', () => {
    it('should set response token usage on session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'response_complete',
        turn: 1,
        tokenUsage: {
          inputTokens: 100,
          outputTokens: 50,
          cacheReadTokens: 10,
          cacheCreationTokens: 5,
        },
      } as unknown as TronEvent;

      handler.handleResponseComplete(ctx, event);

      expect(mockActive.sessionContext!.setResponseTokenUsage).toHaveBeenCalledWith(
        {
          inputTokens: 100,
          outputTokens: 50,
          cacheReadTokens: 10,
          cacheCreationTokens: 5,
        },
        'test-session' // sessionId is passed as second argument
      );
    });

    it('should do nothing when no active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'response_complete',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      } as unknown as TronEvent;

      // Should not throw
      handler.handleResponseComplete(ctx, event);

      expect(ctx.emitCalls).toHaveLength(0);
      expect(ctx.persistCalls).toHaveLength(0);
    });

    it('should do nothing when no token usage in event', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'response_complete',
        turn: 1,
      } as unknown as TronEvent;

      handler.handleResponseComplete(ctx, event);

      expect(mockActive.sessionContext!.setResponseTokenUsage).not.toHaveBeenCalled();
    });
  });

  describe('factory function', () => {
    it('should create TurnEventHandler instance', () => {
      const handler = createTurnEventHandler(deps);
      expect(handler).toBeInstanceOf(TurnEventHandler);
    });
  });
});
