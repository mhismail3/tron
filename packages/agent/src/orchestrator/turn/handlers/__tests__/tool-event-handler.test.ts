/**
 * @fileoverview Tests for ToolEventHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ToolEventHandler, createToolEventHandler, type ToolEventHandlerDeps } from '../tool-event-handler.js';
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

function createMockDeps(): ToolEventHandlerDeps {
  return {
    getActiveSession: vi.fn(),
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
    uiRenderHandler: createMockUIRenderHandler() as unknown as ToolEventHandlerDeps['uiRenderHandler'],
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      registerToolIntents: vi.fn(),
      startToolCall: vi.fn(),
      endToolCall: vi.fn(),
      flushPreToolContent: vi.fn().mockReturnValue(null),
      getCurrentTurn: vi.fn().mockReturnValue(1),
      getTurnStartTime: vi.fn().mockReturnValue(Date.now() - 1000),
      getLastTurnTokenUsage: vi.fn().mockReturnValue({ inputTokens: 100, outputTokens: 50 }),
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

describe('ToolEventHandler', () => {
  let deps: ToolEventHandlerDeps;
  let handler: ToolEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createToolEventHandler(deps);
  });

  describe('handleToolUseBatch', () => {
    it('should register tool intents when active session exists', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_use_batch',
        toolCalls: [
          { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
          { id: 'call-2', name: 'Write', arguments: { file_path: '/out.txt', content: 'hello' } },
        ],
      };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolUseBatch(sessionId, event);

      expect(mockActive.sessionContext!.registerToolIntents).toHaveBeenCalledWith([
        { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
        { id: 'call-2', name: 'Write', arguments: { file_path: '/out.txt', content: 'hello' } },
      ]);
    });

    it('should handle input field as arguments', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_use_batch',
        toolCalls: [
          { id: 'call-1', name: 'Read', input: { file_path: '/test.txt' } },
        ],
      };
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolUseBatch(sessionId, event);

      expect(mockActive.sessionContext!.registerToolIntents).toHaveBeenCalledWith([
        { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
      ]);
    });

    it('should do nothing when no active session', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_use_batch',
        toolCalls: [{ id: 'call-1', name: 'Read', arguments: {} }],
      };

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(undefined);

      handler.handleToolUseBatch(sessionId, event);

      // Should not throw
      expect(deps.emit).not.toHaveBeenCalled();
    });
  });

  describe('handleToolExecutionStart', () => {
    it('should emit agent.tool_start event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionStart(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.tool_start',
        sessionId,
        timestamp,
        data: {
          toolCallId: 'call-1',
          toolName: 'Read',
          arguments: { file_path: '/test.txt' },
        },
      });
    });

    it('should persist tool.call event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionStart(sessionId, event, timestamp);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'tool.call',
        expect.objectContaining({
          toolCallId: 'call-1',
          name: 'Read',
          arguments: { file_path: '/test.txt' },
        })
      );
    });

    it('should track tool call on session context', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolExecutionStart(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.startToolCall).toHaveBeenCalledWith(
        'call-1',
        'Read',
        { file_path: '/test.txt' }
      );
    });

    it('should flush pre-tool content when it exists', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: {},
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      // Return content to flush
      (mockActive.sessionContext!.flushPreToolContent as ReturnType<typeof vi.fn>).mockReturnValue([
        { type: 'text', text: 'Analyzing the file...' },
      ]);

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolExecutionStart(sessionId, event, timestamp);

      // Should create message.assistant before tool.call
      expect(deps.appendEventLinearized).toHaveBeenCalledTimes(2);
      const calls = (deps.appendEventLinearized as ReturnType<typeof vi.fn>).mock.calls;
      expect(calls[0][1]).toBe('message.assistant');
      expect(calls[1][1]).toBe('tool.call');
    });

    it('should delegate RenderAppUI to UIRenderHandler', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        arguments: { component: 'test' },
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionStart(sessionId, event, timestamp);

      expect(deps.uiRenderHandler.handleToolStart).toHaveBeenCalledWith(
        sessionId,
        'call-1',
        { component: 'test' },
        timestamp
      );
    });
  });

  describe('handleToolExecutionEnd', () => {
    it('should emit agent.tool_end event on success', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents here' },
        isError: false,
        duration: 150,
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.tool_end',
        sessionId,
        timestamp,
        data: expect.objectContaining({
          toolCallId: 'call-1',
          toolName: 'Read',
          success: true,
          output: 'file contents here',
          duration: 150,
        }),
      });
    });

    it('should emit agent.tool_end event on error', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'File not found' },
        isError: true,
        duration: 50,
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.tool_end',
        sessionId,
        timestamp,
        data: expect.objectContaining({
          toolCallId: 'call-1',
          toolName: 'Read',
          success: false,
          error: 'File not found',
          duration: 50,
        }),
      });
    });

    it('should persist tool.result event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents' },
        isError: false,
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'tool.result',
        expect.objectContaining({
          toolCallId: 'call-1',
          content: 'file contents',
          isError: false,
        }),
        expect.any(Function)
      );
    });

    it('should track tool result on session context', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents' },
        isError: false,
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.endToolCall).toHaveBeenCalledWith(
        'call-1',
        'file contents',
        false
      );
    });

    it('should extract content from array blocks', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: {
          content: [
            { type: 'text', text: 'Line 1' },
            { type: 'text', text: 'Line 2' },
            { type: 'image', data: 'base64...' },
          ],
        },
        isError: false,
      };
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      (deps.getActiveSession as ReturnType<typeof vi.fn>).mockReturnValue(mockActive);

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(mockActive.sessionContext!.endToolCall).toHaveBeenCalledWith(
        'call-1',
        'Line 1\nLine 2',
        false
      );
    });

    it('should delegate RenderAppUI to UIRenderHandler', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        result: { content: 'success', details: { html: '<div/>' } },
        isError: false,
      };
      const timestamp = new Date().toISOString();

      handler.handleToolExecutionEnd(sessionId, event, timestamp);

      expect(deps.uiRenderHandler.handleToolEnd).toHaveBeenCalledWith(
        sessionId,
        'call-1',
        'success',
        false,
        { html: '<div/>' },
        timestamp
      );
    });
  });

  describe('factory function', () => {
    it('should create ToolEventHandler instance', () => {
      const handler = createToolEventHandler(deps);
      expect(handler).toBeInstanceOf(ToolEventHandler);
    });
  });
});
