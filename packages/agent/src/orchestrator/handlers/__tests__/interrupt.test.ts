/**
 * @fileoverview InterruptHandler Unit Tests
 *
 * Tests for the InterruptHandler which persists interrupted session content.
 *
 * Contract:
 * 1. Build interrupted content from TurnManager
 * 2. Persist message.assistant with interrupted flag
 * 3. Persist tool results as message.user
 * 4. Persist notification.interrupted event
 * 5. Return structured result with event IDs
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  InterruptHandler,
  createInterruptHandler,
  type InterruptContext,
  type InterruptResult,
} from '../interrupt.js';

describe('InterruptHandler', () => {
  let handler: InterruptHandler;

  beforeEach(() => {
    handler = createInterruptHandler();
  });

  describe('buildInterruptEvents()', () => {
    it('should return empty events when no content', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [],
        toolResultContent: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      // Should still have notification event
      expect(events.length).toBe(1);
      expect(events[0].type).toBe('notification.interrupted');
    });

    it('should create message.assistant event for assistant content', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [
          { type: 'text', text: 'Let me help you with that' },
        ],
        toolResultContent: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      expect(events.length).toBe(2);
      expect(events[0].type).toBe('message.assistant');
      expect(events[0].payload).toMatchObject({
        content: [{ type: 'text', text: 'Let me help you with that' }],
        interrupted: true,
        stopReason: 'interrupted',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
      });
    });

    it('should create message.user event for tool results', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [
          { type: 'tool_use', id: 'tc_1', name: 'Read', input: {} },
        ],
        toolResultContent: [
          {
            type: 'tool_result',
            tool_use_id: 'tc_1',
            content: 'file contents',
            is_error: false,
          },
        ],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      expect(events.length).toBe(3);
      expect(events[0].type).toBe('message.assistant');
      expect(events[1].type).toBe('message.user');
      expect(events[1].payload).toMatchObject({
        content: [
          {
            type: 'tool_result',
            tool_use_id: 'tc_1',
            content: 'file contents',
            is_error: false,
          },
        ],
      });
    });

    it('should always include notification.interrupted event', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 3,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [{ type: 'text', text: 'text' }],
        toolResultContent: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      const notificationEvent = events.find(
        e => e.type === 'notification.interrupted'
      );
      expect(notificationEvent).toBeDefined();
      expect(notificationEvent!.payload).toMatchObject({
        turn: 3,
      });
    });

    it('should include token usage in assistant message', () => {
      const tokenUsage = {
        inputTokens: 1000,
        outputTokens: 500,
        cacheReadTokens: 100,
        cacheCreationTokens: 50,
      };

      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [{ type: 'text', text: 'response' }],
        toolResultContent: [],
        tokenUsage,
      };

      const events = handler.buildInterruptEvents(context);

      const assistantEvent = events.find(e => e.type === 'message.assistant');
      expect(assistantEvent!.payload.tokenUsage).toEqual(tokenUsage);
    });

    it('should handle mixed content (text + tool calls)', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [
          { type: 'text', text: 'Let me read the file' },
          { type: 'tool_use', id: 'tc_1', name: 'Read', input: { path: 'a.ts' } },
          { type: 'text', text: 'Now analyzing...' },
        ],
        toolResultContent: [
          {
            type: 'tool_result',
            tool_use_id: 'tc_1',
            content: 'file content',
            is_error: false,
          },
        ],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      expect(events.length).toBe(3);

      const assistantEvent = events.find(e => e.type === 'message.assistant');
      expect(assistantEvent!.payload.content.length).toBe(3);
    });

    it('should preserve tool call metadata in assistant content', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [
          {
            type: 'tool_use',
            id: 'tc_1',
            name: 'Bash',
            input: { command: 'ls' },
            _meta: { status: 'running', interrupted: true },
          },
        ],
        toolResultContent: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      const assistantEvent = events.find(e => e.type === 'message.assistant');
      expect(assistantEvent!.payload.content[0]._meta).toMatchObject({
        status: 'running',
        interrupted: true,
      });
    });
  });

  describe('Edge cases', () => {
    it('should handle empty assistant content with tool results', () => {
      // Edge case: tool results exist but no assistant content
      // This shouldn't happen normally but handler should be robust
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [],
        toolResultContent: [
          {
            type: 'tool_result',
            tool_use_id: 'tc_1',
            content: 'result',
            is_error: false,
          },
        ],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      // Should still create tool result event even without assistant content
      expect(events.some(e => e.type === 'message.user')).toBe(true);
    });

    it('should handle turn 0', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 0,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [{ type: 'text', text: 'text' }],
        toolResultContent: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      };

      const events = handler.buildInterruptEvents(context);

      // Should use turn 1 as minimum
      const notificationEvent = events.find(
        e => e.type === 'notification.interrupted'
      );
      expect(notificationEvent!.payload.turn).toBe(1);
    });

    it('should handle undefined token usage', () => {
      const context: InterruptContext = {
        sessionId: 'session_1',
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        assistantContent: [{ type: 'text', text: 'text' }],
        toolResultContent: [],
      };

      const events = handler.buildInterruptEvents(context);

      const assistantEvent = events.find(e => e.type === 'message.assistant');
      expect(assistantEvent!.payload.tokenUsage).toBeUndefined();
    });
  });
});
