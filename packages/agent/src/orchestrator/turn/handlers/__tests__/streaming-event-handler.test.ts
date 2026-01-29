/**
 * @fileoverview Tests for StreamingEventHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  StreamingEventHandler,
  createStreamingEventHandler,
  type StreamingEventHandlerDeps,
} from '../streaming-event-handler.js';
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

function createMockDeps(): StreamingEventHandlerDeps {
  return {
    getActiveSession: vi.fn(),
    emit: vi.fn(),
    uiRenderHandler: createMockUIRenderHandler() as unknown as StreamingEventHandlerDeps['uiRenderHandler'],
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      addTextDelta: vi.fn(),
      addThinkingDelta: vi.fn(),
      setThinkingSignature: vi.fn(),
    } as unknown as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
}

// =============================================================================
// Tests
// =============================================================================

describe('StreamingEventHandler', () => {
  let deps: StreamingEventHandlerDeps;
  let handler: StreamingEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createStreamingEventHandler(deps);
  });

  describe('handleMessageUpdate', () => {
    it('should accumulate text delta in session context', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'message_update' as const, content: 'Hello world', sessionId, timestamp };
      const mockActive = createMockActiveSession();

      handler.handleMessageUpdate(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addTextDelta).toHaveBeenCalledWith('Hello world');
    });

    it('should emit agent.text_delta event', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'message_update' as const, content: 'Hello', sessionId, timestamp };

      handler.handleMessageUpdate(sessionId, event, timestamp, undefined);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.text_delta',
        sessionId,
        timestamp,
        data: { delta: 'Hello' },
      });
    });

    it('should handle undefined active session', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'message_update' as const, content: 'Hello', sessionId, timestamp };

      handler.handleMessageUpdate(sessionId, event, timestamp, undefined);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });

    it('should accumulate all string content deltas', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'message_update' as const, content: 'Test', sessionId, timestamp };
      const mockActive = createMockActiveSession();

      handler.handleMessageUpdate(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addTextDelta).toHaveBeenCalledWith('Test');
    });
  });

  describe('handleToolCallDelta', () => {
    it('should delegate to UIRenderHandler', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = {
        type: 'toolcall_delta' as const,
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        argumentsDelta: '{"html": "<div',
        sessionId,
        timestamp,
      };

      handler.handleToolCallDelta(sessionId, event, timestamp);

      expect(deps.uiRenderHandler.handleToolCallDelta).toHaveBeenCalledWith(
        sessionId,
        'call-1',
        'RenderAppUI',
        '{"html": "<div',
        timestamp
      );
    });

    it('should handle missing toolName', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = {
        type: 'toolcall_delta' as const,
        toolCallId: 'call-1',
        argumentsDelta: '{}',
        sessionId,
        timestamp,
      };

      handler.handleToolCallDelta(sessionId, event, timestamp);

      expect(deps.uiRenderHandler.handleToolCallDelta).toHaveBeenCalledWith(
        sessionId,
        'call-1',
        undefined,
        '{}',
        timestamp
      );
    });
  });

  describe('handleThinkingStart', () => {
    it('should emit agent.thinking_start event', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();

      handler.handleThinkingStart(sessionId, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.thinking_start',
        sessionId,
        timestamp,
      });
    });
  });

  describe('handleThinkingDelta', () => {
    it('should accumulate thinking delta in session context', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'thinking_delta' as const, delta: 'Let me think...', sessionId, timestamp };
      const mockActive = createMockActiveSession();

      handler.handleThinkingDelta(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addThinkingDelta).toHaveBeenCalledWith('Let me think...');
    });

    it('should emit agent.thinking_delta event', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'thinking_delta' as const, delta: 'Analyzing...', sessionId, timestamp };

      handler.handleThinkingDelta(sessionId, event, timestamp, undefined);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.thinking_delta',
        sessionId,
        timestamp,
        data: { delta: 'Analyzing...' },
      });
    });

    it('should handle undefined active session', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'thinking_delta' as const, delta: 'Thinking...', sessionId, timestamp };

      handler.handleThinkingDelta(sessionId, event, timestamp, undefined);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });
  });

  describe('handleThinkingEnd', () => {
    it('should store signature in session context', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = {
        type: 'thinking_end' as const,
        thinking: 'Complete analysis...',
        signature: 'sig123',
        sessionId,
        timestamp,
      };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleThinkingEnd(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.setThinkingSignature).toHaveBeenCalledWith('sig123');
    });

    it('should emit agent.thinking_end event with signature', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = {
        type: 'thinking_end' as const,
        thinking: 'My analysis...',
        signature: 'sig456',
        sessionId,
        timestamp,
      };

      handler.handleThinkingEnd(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.thinking_end',
        sessionId,
        timestamp,
        data: { thinking: 'My analysis...', signature: 'sig456' },
      });
    });

    it('should handle missing signature', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = { type: 'thinking_end' as const, thinking: 'Done thinking', sessionId, timestamp };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleThinkingEnd(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.setThinkingSignature).not.toHaveBeenCalled();
      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.thinking_end',
        sessionId,
        timestamp,
        data: { thinking: 'Done thinking', signature: undefined },
      });
    });

    it('should handle no active session', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const event = {
        type: 'thinking_end' as const,
        thinking: 'Completed',
        signature: 'sig789',
        sessionId,
        timestamp,
      };

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(undefined);

      handler.handleThinkingEnd(sessionId, event, timestamp);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });
  });

  describe('factory function', () => {
    it('should create StreamingEventHandler instance', () => {
      const handler = createStreamingEventHandler(deps);
      expect(handler).toBeInstanceOf(StreamingEventHandler);
    });
  });
});
