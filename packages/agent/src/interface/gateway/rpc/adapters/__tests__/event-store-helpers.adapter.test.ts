/**
 * @fileoverview Tests for Event Store Adapter Helper Functions
 */

import { describe, it, expect } from 'vitest';
import { getEventSummary, getEventDepth } from '../event-store.adapter.js';
import type { SessionEvent } from '@infrastructure/events/types/index.js';

const createMockEvent = (overrides: Partial<SessionEvent>): SessionEvent => ({
  id: 'evt-mock' as any,
  parentId: null,
  sessionId: 'sess-123' as any,
  workspaceId: 'ws-123' as any,
  timestamp: '2024-01-01T00:00:00Z',
  type: 'message.user',
  sequence: 1,
  payload: { content: '', turn: 1 },
  ...overrides,
} as SessionEvent);

describe('Helper Functions', () => {
  describe('getEventSummary', () => {
    it('should return appropriate summary for session.start', () => {
      const evt = createMockEvent({ type: 'session.start', payload: { workingDirectory: '', model: '' } });
      expect(getEventSummary(evt)).toBe('Session started');
    });

    it('should return appropriate summary for session.end', () => {
      const evt = createMockEvent({ type: 'session.end', payload: { reason: 'completed' } });
      expect(getEventSummary(evt)).toBe('Session ended');
    });

    it('should return fork name for session.fork', () => {
      const evt = createMockEvent({ type: 'session.fork', payload: { sourceSessionId: 'sess-src' as any, sourceEventId: 'evt-src' as any, name: 'my-fork' } });
      expect(getEventSummary(evt)).toBe('Forked: my-fork');
    });

    it('should truncate user message content', () => {
      const longContent = 'A'.repeat(100);
      const evt = createMockEvent({ type: 'message.user', payload: { content: longContent, turn: 1 } });
      expect(getEventSummary(evt)).toBe('A'.repeat(50));
    });

    it('should return tool name for tool.call', () => {
      const evt = createMockEvent({ type: 'tool.call', payload: { toolCallId: 'tc-1', name: 'read_file', arguments: {}, turn: 1 } });
      expect(getEventSummary(evt)).toBe('Tool: read_file');
    });

    it('should return type for unknown events', () => {
      const evt = createMockEvent({ type: 'error.agent', payload: { error: 'test', recoverable: false } });
      expect(getEventSummary(evt)).toBe('error.agent');
    });
  });

  describe('getEventDepth', () => {
    it('should return 0 for root event', () => {
      const evt = createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', payload: { workingDirectory: '', model: '' } });
      const events: SessionEvent[] = [evt];
      const eventOrUndef = events[0];
      if (eventOrUndef) {
        expect(getEventDepth(eventOrUndef, events)).toBe(0);
      }
    });

    it('should return correct depth for nested events', () => {
      const evt1 = createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } });
      const evt2 = createMockEvent({ id: 'evt-2' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } });
      const evt3 = createMockEvent({ id: 'evt-3' as any, parentId: 'evt-2' as any, type: 'message.assistant', sequence: 3, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } });
      const events: SessionEvent[] = [evt1, evt2, evt3];
      const eventOrUndef = events[2];
      if (eventOrUndef) {
        expect(getEventDepth(eventOrUndef, events)).toBe(2);
      }
    });
  });
});
