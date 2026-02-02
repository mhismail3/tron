/**
 * @fileoverview Tests for StreamingEventHandler
 *
 * StreamingEventHandler uses EventContext for automatic metadata injection.
 * It only emits events (no persistence) - streaming events are ephemeral.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  StreamingEventHandler,
  createStreamingEventHandler,
  type StreamingEventHandlerDeps,
} from '../streaming-event-handler.js';
import { createTestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';
import type { EventContext } from '../../event-context.js';

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

function createTestContext(options: {
  sessionId?: SessionId;
  runId?: string;
  active?: ActiveSession;
} = {}) {
  return createTestEventContext({
    sessionId: options.sessionId ?? ('test-session' as SessionId),
    runId: options.runId,
    active: options.active,
  });
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
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'message_update' as const, content: 'Hello world' };

      handler.handleMessageUpdate(ctx, event);

      expect(mockActive.sessionContext!.addTextDelta).toHaveBeenCalledWith('Hello world');
    });

    it('should emit agent.text_delta event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'message_update' as const, content: 'Hello' };

      handler.handleMessageUpdate(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.text_delta',
        data: { delta: 'Hello' },
      });
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = { type: 'message_update' as const, content: 'Hello' };

      handler.handleMessageUpdate(ctx, event);

      // Should still emit event
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.text_delta');
    });

    it('should handle non-string content', () => {
      const mockActive = createMockActiveSession();
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'message_update' as const, content: undefined };

      handler.handleMessageUpdate(ctx, event);

      // Should not call addTextDelta for non-string content
      expect(mockActive.sessionContext!.addTextDelta).not.toHaveBeenCalled();
      // But should still emit
      expect(ctx.emitCalls).toHaveLength(1);
    });
  });

  describe('handleToolCallDelta', () => {
    it('should delegate to UIRenderHandler with runId from context', () => {
      const ctx = createTestContext({ runId: 'run-123' });
      const event = {
        type: 'toolcall_delta' as const,
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        argumentsDelta: '{"html": "<div',
      };

      handler.handleToolCallDelta(ctx, event);

      expect(deps.uiRenderHandler.handleToolCallDelta).toHaveBeenCalledWith(
        ctx.sessionId,
        'call-1',
        'RenderAppUI',
        '{"html": "<div',
        ctx.timestamp,
        'run-123'
      );
    });

    it('should handle missing toolName', () => {
      const ctx = createTestContext({ runId: 'run-456' });
      const event = {
        type: 'toolcall_delta' as const,
        toolCallId: 'call-1',
        argumentsDelta: '{}',
      };

      handler.handleToolCallDelta(ctx, event);

      expect(deps.uiRenderHandler.handleToolCallDelta).toHaveBeenCalledWith(
        ctx.sessionId,
        'call-1',
        undefined,
        '{}',
        ctx.timestamp,
        'run-456'
      );
    });

    it('should handle undefined runId', () => {
      const ctx = createTestContext(); // No runId
      const event = {
        type: 'toolcall_delta' as const,
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        argumentsDelta: '{}',
      };

      handler.handleToolCallDelta(ctx, event);

      expect(deps.uiRenderHandler.handleToolCallDelta).toHaveBeenCalledWith(
        ctx.sessionId,
        'call-1',
        'RenderAppUI',
        '{}',
        ctx.timestamp,
        undefined
      );
    });
  });

  describe('handleThinkingStart', () => {
    it('should emit agent.thinking_start event via context', () => {
      const ctx = createTestContext({ runId: 'run-123' });

      handler.handleThinkingStart(ctx);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.thinking_start',
        data: undefined,
      });
    });

    it('should work without runId', () => {
      const ctx = createTestContext(); // No runId

      handler.handleThinkingStart(ctx);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.thinking_start');
    });
  });

  describe('handleThinkingDelta', () => {
    it('should accumulate thinking delta in session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'thinking_delta' as const, delta: 'Let me think...' };

      handler.handleThinkingDelta(ctx, event);

      expect(mockActive.sessionContext!.addThinkingDelta).toHaveBeenCalledWith('Let me think...');
    });

    it('should emit agent.thinking_delta event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'thinking_delta' as const, delta: 'Analyzing...' };

      handler.handleThinkingDelta(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.thinking_delta',
        data: { delta: 'Analyzing...' },
      });
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = { type: 'thinking_delta' as const, delta: 'Thinking...' };

      handler.handleThinkingDelta(ctx, event);

      // Should still emit event
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.thinking_delta');
    });
  });

  describe('handleThinkingEnd', () => {
    it('should store signature in session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'thinking_end' as const,
        thinking: 'Complete analysis...',
        signature: 'sig123',
      };

      handler.handleThinkingEnd(ctx, event);

      expect(mockActive.sessionContext!.setThinkingSignature).toHaveBeenCalledWith('sig123');
    });

    it('should emit agent.thinking_end event with signature', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'thinking_end' as const,
        thinking: 'My analysis...',
        signature: 'sig456',
      };

      handler.handleThinkingEnd(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.thinking_end',
        data: { thinking: 'My analysis...', signature: 'sig456' },
      });
    });

    it('should handle missing signature', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });
      const event = { type: 'thinking_end' as const, thinking: 'Done thinking' };

      handler.handleThinkingEnd(ctx, event);

      expect(mockActive.sessionContext!.setThinkingSignature).not.toHaveBeenCalled();
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.thinking_end',
        data: { thinking: 'Done thinking', signature: undefined },
      });
    });

    it('should handle no active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'thinking_end' as const,
        thinking: 'Completed',
        signature: 'sig789',
      };

      handler.handleThinkingEnd(ctx, event);

      // Should still emit event
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].type).toBe('agent.thinking_end');
    });
  });

  describe('factory function', () => {
    it('should create StreamingEventHandler instance', () => {
      const handler = createStreamingEventHandler(deps);
      expect(handler).toBeInstanceOf(StreamingEventHandler);
    });
  });
});
