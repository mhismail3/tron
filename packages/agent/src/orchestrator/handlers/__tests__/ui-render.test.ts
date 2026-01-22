/**
 * @fileoverview Tests for UI Render event handling in AgentEventHandler
 *
 * TDD: Validates the ui_render_retry event emission when tool returns needsRetry.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentEventHandler } from '../../agent-event-handler.js';

describe('AgentEventHandler - UI Render Events', () => {
  let handler: AgentEventHandler;
  let mockEmit: ReturnType<typeof vi.fn>;
  let mockAppendEventLinearized: ReturnType<typeof vi.fn>;
  let mockGetActiveSession: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockEmit = vi.fn();
    mockAppendEventLinearized = vi.fn();
    mockGetActiveSession = vi.fn().mockReturnValue({
      sessionContext: {
        startToolCall: vi.fn(),
        endToolCall: vi.fn(),
        getCurrentTurn: vi.fn().mockReturnValue(1),
        flushPreToolContent: vi.fn().mockReturnValue(null),
        hasPreToolContentFlushed: vi.fn().mockReturnValue(false),
      },
      model: 'claude-opus-4-5-20251101',
      messageEventIds: [],
    });

    handler = new AgentEventHandler({
      defaultProvider: 'anthropic',
      getActiveSession: mockGetActiveSession,
      appendEventLinearized: mockAppendEventLinearized,
      emit: mockEmit,
    });
  });

  describe('ui_render_retry event', () => {
    it('should emit ui_render_retry when tool returns needsRetry', () => {
      // First simulate tool start
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      // Then simulate tool end with needsRetry
      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'UI validation failed (attempt 1/3). Fix these errors:\nButton requires label',
          details: {
            needsRetry: true,
            canvasId: 'test-canvas',
            attempt: 1,
          },
        },
      });

      // Check that ui_render_retry was emitted
      const retryCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_retry'
      );
      expect(retryCall).toBeDefined();
      expect(retryCall[1].data).toEqual(
        expect.objectContaining({
          canvasId: 'test-canvas',
          attempt: 1,
        })
      );
    });

    it('should NOT emit ui_render_complete when needsRetry is true', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'Validation failed...',
          details: { needsRetry: true, canvasId: 'test' },
        },
      });

      const completeCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_complete'
      );
      expect(completeCall).toBeUndefined();
    });

    it('should NOT emit ui_render_error when needsRetry is true', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'Validation failed...',
          details: { needsRetry: true, canvasId: 'test' },
        },
      });

      const errorCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_error'
      );
      expect(errorCall).toBeUndefined();
    });

    it('should include errors from content in retry event', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'canvas-123' },
      });

      const errorContent = 'UI validation failed (attempt 2/3). Fix these errors:\nButton requires label\nButton requires actionId';
      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: errorContent,
          details: {
            needsRetry: true,
            canvasId: 'canvas-123',
            attempt: 2,
          },
        },
      });

      const retryCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_retry'
      );
      expect(retryCall).toBeDefined();
      expect(retryCall[1].data.errors).toContain('Button requires label');
    });
  });

  describe('ui_render_complete event', () => {
    it('should emit ui_render_complete when validation passes', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'UI canvas "test-canvas" rendered.',
          details: {
            canvasId: 'test-canvas',
            ui: { $tag: 'Text', $children: 'Hello' },
          },
        },
      });

      const completeCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_complete'
      );
      expect(completeCall).toBeDefined();
      expect(completeCall[1].data).toEqual(
        expect.objectContaining({
          canvasId: 'test-canvas',
          ui: { $tag: 'Text', $children: 'Hello' },
        })
      );
    });

    it('should include state in complete event when provided', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'UI canvas rendered.',
          details: {
            canvasId: 'test-canvas',
            ui: { $tag: 'Toggle', $props: { label: 'Enable', bindingId: 'toggle1' } },
            state: { toggle1: true },
          },
        },
      });

      const completeCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_complete'
      );
      expect(completeCall).toBeDefined();
      expect(completeCall[1].data.state).toEqual({ toggle1: true });
    });
  });

  describe('ui_render_error event', () => {
    it('should emit ui_render_error when isError is true', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: true,
        result: {
          content: 'Failed to render valid UI after 3 attempts:\nButton requires label',
          details: {
            canvasId: 'test-canvas',
          },
        },
      });

      const errorCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.ui_render_error'
      );
      expect(errorCall).toBeDefined();
      expect(errorCall[1].data).toEqual(
        expect.objectContaining({
          canvasId: 'test-canvas',
          error: expect.stringContaining('Failed'),
        })
      );
    });
  });

  describe('regression tests', () => {
    it('should still emit agent.tool_start for RenderAppUI', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      const toolStartCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.tool_start'
      );
      expect(toolStartCall).toBeDefined();
    });

    it('should still emit agent.tool_end for RenderAppUI', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'UI rendered.',
          details: { canvasId: 'test-canvas', ui: { $tag: 'Text' } },
        },
      });

      const toolEndCall = mockEmit.mock.calls.find(
        (call) => call[0] === 'agent_event' && call[1]?.type === 'agent.tool_end'
      );
      expect(toolEndCall).toBeDefined();
    });

    it('should still persist tool.result event', () => {
      handler.forwardEvent('test-session', {
        type: 'tool_execution_start',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        arguments: { canvasId: 'test-canvas' },
      });

      handler.forwardEvent('test-session', {
        type: 'tool_execution_end',
        toolCallId: 'tc-1',
        toolName: 'RenderAppUI',
        isError: false,
        result: {
          content: 'UI rendered.',
          details: { canvasId: 'test-canvas', ui: { $tag: 'Text' } },
        },
      });

      const persistCall = mockAppendEventLinearized.mock.calls.find(
        (call) => call[1] === 'tool.result'
      );
      expect(persistCall).toBeDefined();
    });
  });
});
