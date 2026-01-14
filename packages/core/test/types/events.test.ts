/**
 * @fileoverview Tests for Tron streaming event types
 *
 * TDD: Tests for all event types emitted during agent operation.
 */

import { describe, it, expect } from 'vitest';
import type {
  StreamEvent,
  TronEvent,
  TronEventType,
} from '../../src/types/events.js';

describe('Event Types', () => {
  describe('StreamEvent (LLM streaming)', () => {
    it('should define start event', () => {
      const event: StreamEvent = { type: 'start' };
      expect(event.type).toBe('start');
    });

    it('should define text events', () => {
      const start: StreamEvent = { type: 'text_start' };
      const delta: StreamEvent = { type: 'text_delta', delta: 'Hello' };
      const end: StreamEvent = { type: 'text_end', text: 'Hello world' };

      expect(start.type).toBe('text_start');
      expect(delta.type).toBe('text_delta');
      expect((delta as { type: 'text_delta'; delta: string }).delta).toBe('Hello');
      expect(end.type).toBe('text_end');
    });

    it('should define thinking events', () => {
      const start: StreamEvent = { type: 'thinking_start' };
      const delta: StreamEvent = { type: 'thinking_delta', delta: 'Let me think...' };
      const end: StreamEvent = { type: 'thinking_end', thinking: 'Full thinking content' };

      expect(start.type).toBe('thinking_start');
      expect((delta as { type: 'thinking_delta'; delta: string }).delta).toBe('Let me think...');
      expect((end as { type: 'thinking_end'; thinking: string }).thinking).toBe('Full thinking content');
    });

    it('should define tool call events', () => {
      const start: StreamEvent = {
        type: 'toolcall_start',
        toolCallId: 'call_123',
        name: 'read',
      };
      const delta: StreamEvent = {
        type: 'toolcall_delta',
        toolCallId: 'call_123',
        argumentsDelta: '{"path":',
      };
      const end: StreamEvent = {
        type: 'toolcall_end',
        toolCall: {
          type: 'tool_use',
          id: 'call_123',
          name: 'read',
          arguments: { path: '/test.txt' },
        },
      };

      expect((start as { type: 'toolcall_start'; name: string }).name).toBe('read');
      expect((delta as { type: 'toolcall_delta'; argumentsDelta: string }).argumentsDelta).toBe('{"path":');
      expect((end as { type: 'toolcall_end'; toolCall: { name: string } }).toolCall.name).toBe('read');
    });

    it('should define done event with message', () => {
      const event: StreamEvent = {
        type: 'done',
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: 'Response' }],
        },
        stopReason: 'end_turn',
      };

      expect(event.type).toBe('done');
      expect((event as { type: 'done'; stopReason: string }).stopReason).toBe('end_turn');
    });

    it('should define error event', () => {
      const event: StreamEvent = {
        type: 'error',
        error: new Error('API error'),
      };

      expect(event.type).toBe('error');
      expect((event as { type: 'error'; error: Error }).error.message).toBe('API error');
    });
  });

  describe('TronEvent (Agent-level events)', () => {
    it('should define agent lifecycle events', () => {
      const start: TronEvent = { type: 'agent_start', sessionId: 'sess_123', timestamp: Date.now() };
      const end: TronEvent = { type: 'agent_end', sessionId: 'sess_123', timestamp: Date.now() };

      expect(start.type).toBe('agent_start');
      expect(end.type).toBe('agent_end');
    });

    it('should define turn events', () => {
      const start: TronEvent = { type: 'turn_start', sessionId: 'sess_123', timestamp: Date.now() };
      const end: TronEvent = { type: 'turn_end', sessionId: 'sess_123', timestamp: Date.now() };

      expect(start.type).toBe('turn_start');
      expect(end.type).toBe('turn_end');
    });

    it('should define turn_end with contextLimit for context tracking', () => {
      const turnEnd: TronEvent = {
        type: 'turn_end',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 1,
        duration: 1000,
        tokenUsage: {
          inputTokens: 5000,
          outputTokens: 1000,
          cacheReadTokens: 2000,
          cacheCreationTokens: 500,
        },
        contextLimit: 200_000, // NEW: Current model's context limit
      };

      expect(turnEnd.type).toBe('turn_end');
      expect((turnEnd as { contextLimit?: number }).contextLimit).toBe(200_000);
    });

    it('should allow turn_end without contextLimit for backwards compatibility', () => {
      const turnEnd: TronEvent = {
        type: 'turn_end',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 1,
        duration: 500,
      };

      expect(turnEnd.type).toBe('turn_end');
      expect((turnEnd as { contextLimit?: number }).contextLimit).toBeUndefined();
    });

    it('should define message update events', () => {
      const event: TronEvent = {
        type: 'message_update',
        sessionId: 'sess_123',
        timestamp: Date.now(),
        event: { type: 'text_delta', delta: 'Hello' },
      };

      expect(event.type).toBe('message_update');
    });

    it('should define tool execution events', () => {
      const start: TronEvent = {
        type: 'tool_execution_start',
        sessionId: 'sess_123',
        timestamp: Date.now(),
        toolCallId: 'call_123',
        name: 'read',
        arguments: { path: '/test.txt' },
      };

      const update: TronEvent = {
        type: 'tool_execution_update',
        sessionId: 'sess_123',
        timestamp: Date.now(),
        toolCallId: 'call_123',
        update: 'Reading line 50...',
      };

      const end: TronEvent = {
        type: 'tool_execution_end',
        sessionId: 'sess_123',
        timestamp: Date.now(),
        toolCallId: 'call_123',
        result: {
          content: [{ type: 'text', text: 'file contents' }],
        },
      };

      expect(start.type).toBe('tool_execution_start');
      expect(update.type).toBe('tool_execution_update');
      expect(end.type).toBe('tool_execution_end');
    });

    it('should include sessionId and timestamp on all events', () => {
      const eventTypes: TronEventType[] = [
        'agent_start',
        'agent_end',
        'turn_start',
        'turn_end',
      ];

      eventTypes.forEach(type => {
        const event: TronEvent = {
          type,
          sessionId: 'sess_123',
          timestamp: Date.now(),
        } as TronEvent;

        expect(event.sessionId).toBe('sess_123');
        expect(event.timestamp).toBeDefined();
      });
    });
  });
});
