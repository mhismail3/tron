/**
 * @fileoverview Tests for TurnEventHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { TurnEventHandler, createTurnEventHandler, type TurnEventHandlerDeps } from '../turn-event-handler.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): TurnEventHandlerDeps {
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
        normalizedUsage: { newInputTokens: 100, contextWindowTokens: 1000, outputTokens: 50 },
      }),
      hasPreToolContentFlushed: vi.fn().mockReturnValue(false),
      getTurnStartTime: vi.fn().mockReturnValue(Date.now() - 1000),
      setResponseTokenUsage: vi.fn(),
      getLastNormalizedUsage: vi.fn().mockReturnValue({
        newInputTokens: 100,
        contextWindowTokens: 1000,
        outputTokens: 50,
      }),
      addMessageEventId: vi.fn(),
    } as unknown as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
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
    it('should emit agent.turn_start event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'turn_start', turn: 1 };
      const timestamp = new Date().toISOString();

      handler.handleTurnStart(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.turn_start',
        sessionId,
        timestamp,
        data: { turn: 1 },
      });
    });

    it('should persist stream.turn_start event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'turn_start', turn: 1 };
      const timestamp = new Date().toISOString();

      handler.handleTurnStart(sessionId, event, timestamp);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'stream.turn_start',
        { turn: 1 }
      );
    });

    it('should call startTurn on session context when active session exists', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'turn_start', turn: 2 };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleTurnStart(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.startTurn).toHaveBeenCalledWith(2);
    });

    it('should not call startTurn when turn is undefined', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'turn_start' };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleTurnStart(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.startTurn).not.toHaveBeenCalled();
    });
  });

  describe('handleTurnEnd', () => {
    it('should emit agent.turn_end event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'turn_end',
        turn: 1,
        duration: 1000,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
      const timestamp = new Date().toISOString();

      handler.handleTurnEnd(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', expect.objectContaining({
        type: 'agent.turn_end',
        sessionId,
        timestamp,
      }));
    });

    it('should persist stream.turn_end event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
      const timestamp = new Date().toISOString();

      handler.handleTurnEnd(sessionId, event, timestamp);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'stream.turn_end',
        expect.objectContaining({
          turn: 1,
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
        })
      );
    });

    it('should create message.assistant when content exists and not pre-flushed', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      // Mock endTurn to return content
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [{ type: 'text', text: 'Hello world' }],
        normalizedUsage: { newInputTokens: 100, contextWindowTokens: 1000, outputTokens: 50 },
      });

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleTurnEnd(sessionId, event, timestamp);

      // Should call appendEventLinearized twice: message.assistant and stream.turn_end
      expect(deps.appendEventLinearized).toHaveBeenCalledTimes(2);
      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'message.assistant',
        expect.objectContaining({
          turn: 1,
          stopReason: 'end_turn',
        }),
        expect.any(Function)
      );
    });

    it('should skip message.assistant when content was pre-flushed for tools', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      // Mark as pre-flushed (tools were called)
      (mockActive.sessionContext!.hasPreToolContentFlushed as ReturnType<typeof vi.fn>).mockReturnValue(true);
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [{ type: 'text', text: 'Hello world' }],
        normalizedUsage: { newInputTokens: 100, contextWindowTokens: 1000, outputTokens: 50 },
      });

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleTurnEnd(sessionId, event, timestamp);

      // Should only call appendEventLinearized once for stream.turn_end
      expect(deps.appendEventLinearized).toHaveBeenCalledTimes(1);
      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'stream.turn_end',
        expect.any(Object)
      );
    });

    it('should sync context tokens to ContextManager', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'turn_end',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();
      const mockSetApiContextTokens = vi.fn();

      (mockActive.agent.getContextManager as ReturnType<typeof vi.fn>).mockReturnValue({
        setApiContextTokens: mockSetApiContextTokens,
      });
      (mockActive.sessionContext!.endTurn as ReturnType<typeof vi.fn>).mockReturnValue({
        turn: 1,
        content: [],
        normalizedUsage: { contextWindowTokens: 5000 },
      });

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleTurnEnd(sessionId, event, timestamp);

      expect(mockSetApiContextTokens).toHaveBeenCalledWith(5000);
    });
  });

  describe('handleResponseComplete', () => {
    it('should set response token usage on session context', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'response_complete',
        turn: 1,
        tokenUsage: {
          inputTokens: 100,
          outputTokens: 50,
          cacheReadTokens: 10,
          cacheCreationTokens: 5,
        },
      };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleResponseComplete(sessionId, event);

      expect(mockActive.sessionContext!.setResponseTokenUsage).toHaveBeenCalledWith({
        inputTokens: 100,
        outputTokens: 50,
        cacheReadTokens: 10,
        cacheCreationTokens: 5,
      });
    });

    it('should do nothing when no active session', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'response_complete',
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(undefined);

      // Should not throw
      handler.handleResponseComplete(sessionId, event);

      expect(deps.emit).not.toHaveBeenCalled();
    });

    it('should do nothing when no token usage in event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'response_complete', turn: 1 };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleResponseComplete(sessionId, event);

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
