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
      const event = { type: 'message_update', content: 'Hello world' };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      handler.handleMessageUpdate(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addTextDelta).toHaveBeenCalledWith('Hello world');
    });

    it('should emit agent.text_delta event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'message_update', content: 'Hello' };
      const timestamp = new Date().toISOString();

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
      const event = { type: 'message_update', content: 'Hello' };
      const timestamp = new Date().toISOString();

      handler.handleMessageUpdate(sessionId, event, timestamp, undefined);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });

    it('should not accumulate non-string content', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'message_update', content: undefined };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      handler.handleMessageUpdate(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addTextDelta).not.toHaveBeenCalled();
    });
  });

  describe('handleToolCallDelta', () => {
    it('should delegate to UIRenderHandler', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'toolcall_delta',
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        argumentsDelta: '{"html": "<div',
      };
      const timestamp = new Date().toISOString();

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
      const event = {
        type: 'toolcall_delta',
        toolCallId: 'call-1',
        argumentsDelta: '{}',
      };
      const timestamp = new Date().toISOString();

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
      const event = { type: 'thinking_delta', delta: 'Let me think...' };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      handler.handleThinkingDelta(sessionId, event, timestamp, mockActive);

      expect(mockActive.sessionContext!.addThinkingDelta).toHaveBeenCalledWith('Let me think...');
    });

    it('should emit agent.thinking_delta event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'thinking_delta', delta: 'Analyzing...' };
      const timestamp = new Date().toISOString();

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
      const event = { type: 'thinking_delta', delta: 'Thinking...' };
      const timestamp = new Date().toISOString();

      handler.handleThinkingDelta(sessionId, event, timestamp, undefined);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });
  });

  describe('handleThinkingEnd', () => {
    it('should store signature in session context', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'thinking_end',
        thinking: 'Complete analysis...',
        signature: 'sig123',
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleThinkingEnd(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.setThinkingSignature).toHaveBeenCalledWith('sig123');
    });

    it('should emit agent.thinking_end event with signature', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'thinking_end',
        thinking: 'My analysis...',
        signature: 'sig456',
      };
      const timestamp = new Date().toISOString();

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
      const event = { type: 'thinking_end', thinking: 'Done thinking' };
      const timestamp = new Date().toISOString();
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
      const event = {
        type: 'thinking_end',
        thinking: 'Completed',
        signature: 'sig789',
      };
      const timestamp = new Date().toISOString();

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
