/**
 * @fileoverview Tests for Event Store Adapter
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createEventStoreAdapter, getEventSummary, getEventDepth } from '../event-store.adapter.js';
import type { EventStoreOrchestrator } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';
import type { SessionEvent } from '@infrastructure/events/types/index.js';

// Define SearchResult inline to avoid heavy import
interface SearchResult {
  eventId: any;
  sessionId: any;
  type: string;
  timestamp: string;
  snippet: string;
  score: number;
}

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

// =============================================================================
// Helper Functions Tests
// =============================================================================

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

// =============================================================================
// Adapter Tests
// =============================================================================

describe('EventStoreAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;
  let mockEventStore: any;

  beforeEach(() => {
    mockEventStore = {
      getSession: vi.fn(),
      getChildren: vi.fn(),
    };

    mockOrchestrator = {
      getEventStore: vi.fn().mockReturnValue(mockEventStore),
      events: {
        getEvents: vi.fn(),
        append: vi.fn(),
        getAncestors: vi.fn(),
        search: vi.fn(),
        deleteMessage: vi.fn(),
      } as any,
    };
  });

  // ===========================================================================
  // History Operations
  // ===========================================================================

  describe('getEventHistory', () => {
    it('should return events in reverse chronological order', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, type: 'message.assistant', sequence: 3, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123');

      expect(mockOrchestrator.events!.getEvents).toHaveBeenCalledWith('sess-123');
      expect(result.events).toHaveLength(3);
      expect((result.events[0] as any).id).toBe('evt-3');
      expect((result.events[2] as any).id).toBe('evt-1');
    });

    it('should filter by event types when specified', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, type: 'message.assistant', sequence: 3, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
        createMockEvent({ id: 'evt-4' as any, type: 'tool.call', sequence: 4, payload: { toolCallId: 'tc-1', name: 'read_file', arguments: {}, turn: 1 } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123', {
        types: ['message.user', 'message.assistant'],
      });

      expect(result.events).toHaveLength(2);
      expect(result.events.every((e: any) => e.type.startsWith('message.'))).toBe(true);
    });

    it('should respect limit parameter', async () => {
      const mockEvents: SessionEvent[] = Array.from({ length: 200 }, (_, i) =>
        createMockEvent({ id: `evt-${i}` as any, type: 'message.user', sequence: i + 1, payload: { content: '', turn: 1 } })
      );
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123', { limit: 50 });

      expect(result.events).toHaveLength(50);
      expect(result.hasMore).toBe(true);
    });

    it('should return hasMore false when all events fit', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'message.user', sequence: 1, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.assistant', sequence: 2, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123', { limit: 100 });

      expect(result.hasMore).toBe(false);
    });
  });

  describe('getEventsSince', () => {
    it('should return events after specified eventId', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, type: 'message.assistant', sequence: 3, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventsSince({
        sessionId: 'sess-123',
        afterEventId: 'evt-1',
      });

      expect(result.events).toHaveLength(2);
      expect((result.events[0] as any).id).toBe('evt-2');
    });

    it('should return events after specified timestamp', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, timestamp: '2024-01-01T00:00:00Z', payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, timestamp: '2024-01-01T00:01:00Z', payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, type: 'message.assistant', sequence: 3, timestamp: '2024-01-01T00:02:00Z', payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventsSince({
        sessionId: 'sess-123',
        afterTimestamp: '2024-01-01T00:00:30Z',
      });

      expect(result.events).toHaveLength(2);
    });

    it('should return empty when no sessionId provided', async () => {
      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventsSince({});

      expect(result.events).toEqual([]);
    });
  });

  describe('appendEvent', () => {
    it('should append event and return new head', async () => {
      const mockEvent = { id: 'evt-new', type: 'message.user', payload: { content: 'Hello' } };
      vi.mocked(mockOrchestrator.events!.append).mockResolvedValue(mockEvent as any);
      mockEventStore.getSession.mockResolvedValue({ headEventId: 'evt-new' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.appendEvent('sess-123', 'message.user', { content: 'Hello' });

      expect(mockOrchestrator.events!.append).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: undefined,
      });
      expect(result.event).toEqual(mockEvent);
      expect(result.newHeadEventId).toBe('evt-new');
    });

    it('should pass parentId when provided', async () => {
      const mockEvent = { id: 'evt-new', type: 'custom.event' };
      vi.mocked(mockOrchestrator.events!.append).mockResolvedValue(mockEvent as any);
      mockEventStore.getSession.mockResolvedValue({ headEventId: 'evt-new' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      await adapter.appendEvent('sess-123', 'custom.event', { data: 'test' }, 'evt-parent');

      expect(mockOrchestrator.events!.append).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        type: 'custom.event',
        payload: { data: 'test' },
        parentId: 'evt-parent',
      });
    });
  });

  // ===========================================================================
  // Tree Operations
  // ===========================================================================

  describe('getTreeVisualization', () => {
    it('should return tree with node metadata', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 2, payload: { content: 'Hello', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, parentId: 'evt-2' as any, type: 'message.assistant', sequence: 3, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({
        rootEventId: 'evt-1',
        headEventId: 'evt-3',
      });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getTreeVisualization('sess-123');

      expect(result.sessionId).toBe('sess-123');
      expect(result.rootEventId).toBe('evt-1');
      expect(result.headEventId).toBe('evt-3');
      expect(result.nodes).toHaveLength(3);
      expect(result.totalEvents).toBe(3);

      const rootNode = result.nodes.find((n: any) => n.id === 'evt-1') as any;
      expect(rootNode?.depth).toBe(0);
      expect(rootNode?.hasChildren).toBe(true);
    });

    it('should filter to messages only when requested', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, parentId: 'evt-2' as any, type: 'tool.call', sequence: 3, payload: { toolCallId: 'tc-1', name: 'read_file', arguments: {}, turn: 1 } }),
        createMockEvent({ id: 'evt-4' as any, parentId: 'evt-3' as any, type: 'message.assistant', sequence: 4, payload: { content: [], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn', model: 'claude-3-5-sonnet' } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({ rootEventId: 'evt-1', headEventId: 'evt-4' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getTreeVisualization('sess-123', { messagesOnly: true });

      expect(result.nodes).toHaveLength(2);
    });

    it('should throw when session not found', async () => {
      mockEventStore.getSession.mockResolvedValue(null);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      await expect(adapter.getTreeVisualization('nonexistent')).rejects.toThrow('Session not found');
    });
  });

  describe('getBranches', () => {
    it('should identify branch points with multiple children', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
        createMockEvent({ id: 'evt-3' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 3, payload: { content: '', turn: 1 } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({ headEventId: 'evt-2' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getBranches('sess-123');

      expect(result.mainBranch).toBeDefined();
      expect(result.forks).toHaveLength(1);
    });

    it('should return single main branch when no forks', async () => {
      const mockEvents: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, parentId: null, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, parentId: 'evt-1' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({ headEventId: 'evt-2' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getBranches('sess-123');

      expect(result.mainBranch).toBeDefined();
      expect((result.mainBranch as any)?.isMain).toBe(true);
      expect(result.forks).toHaveLength(0);
    });
  });

  // ===========================================================================
  // Search & Navigation
  // ===========================================================================

  describe('getSubtree', () => {
    it('should return ancestors when direction is ancestors', async () => {
      const mockAncestors: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
      ];
      vi.mocked(mockOrchestrator.events!.getAncestors).mockResolvedValue(mockAncestors);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getSubtree('evt-3', { direction: 'ancestors' });

      expect(mockOrchestrator.events!.getAncestors).toHaveBeenCalledWith('evt-3');
      expect(result.nodes).toEqual(mockAncestors);
    });

    it('should return descendants by default', async () => {
      const mockChildren: SessionEvent[] = [createMockEvent({ id: 'evt-child' as any, type: 'message.user', sequence: 1, payload: { content: '', turn: 1 } })];
      // Return children for parent, empty for recursive calls to prevent infinite recursion
      mockEventStore.getChildren
        .mockResolvedValueOnce(mockChildren)
        .mockResolvedValue([]);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getSubtree('evt-parent');

      expect(mockEventStore.getChildren).toHaveBeenCalledWith('evt-parent');
      expect(result.nodes).toHaveLength(1);
    });
  });

  describe('getAncestors', () => {
    it('should return ancestor events', async () => {
      const mockAncestors: SessionEvent[] = [
        createMockEvent({ id: 'evt-1' as any, type: 'session.start', sequence: 1, payload: { workingDirectory: '', model: '' } }),
        createMockEvent({ id: 'evt-2' as any, type: 'message.user', sequence: 2, payload: { content: '', turn: 1 } }),
      ];
      vi.mocked(mockOrchestrator.events!.getAncestors).mockResolvedValue(mockAncestors);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getAncestors('evt-3');

      expect(mockOrchestrator.events!.getAncestors).toHaveBeenCalledWith('evt-3');
      expect(result.events).toEqual(mockAncestors);
    });
  });

  describe('searchContent', () => {
    it('should search events and return results', async () => {
      const mockResults: SearchResult[] = [
        {
          eventId: 'evt-1' as any,
          sessionId: 'sess-123' as any,
          type: 'message.user',
          timestamp: '2024-01-01T00:00:00Z',
          snippet: 'Hello world',
          score: 0.95,
        },
      ];
      vi.mocked(mockOrchestrator.events!.search).mockResolvedValue(mockResults as any);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.searchContent('hello', { sessionId: 'sess-123', limit: 10 });

      expect(mockOrchestrator.events!.search).toHaveBeenCalledWith('hello', {
        sessionId: 'sess-123',
        workspaceId: undefined,
        types: undefined,
        limit: 10,
      });
      expect(result.results).toEqual(mockResults);
      expect(result.totalCount).toBe(1);
    });
  });

  describe('deleteMessage', () => {
    it('should delegate to orchestrator', async () => {
      const mockResult = createMockEvent({
        id: 'evt-deleted' as any,
        type: 'message.deleted',
        sequence: 10,
        payload: { targetEventId: 'evt-1' as any, targetType: 'message.user' },
      });
      vi.mocked(mockOrchestrator.events!.deleteMessage).mockResolvedValue(mockResult as any);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.deleteMessage('sess-123', 'evt-1', 'user_request');

      expect(mockOrchestrator.events!.deleteMessage).toHaveBeenCalledWith('sess-123', 'evt-1', 'user_request');
      // Adapter returns { id, payload }, not full event
      expect(result).toEqual({
        id: 'evt-deleted',
        payload: { targetEventId: 'evt-1', targetType: 'message.user' },
      });
    });
  });
});
