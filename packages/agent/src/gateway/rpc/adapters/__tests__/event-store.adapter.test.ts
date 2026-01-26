/**
 * @fileoverview Tests for Event Store Adapter
 *
 * The event store adapter handles event operations including history,
 * tree visualization, branches, and search.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createEventStoreAdapter, getEventSummary, getEventDepth } from '../event-store.adapter.js';
import type { EventStoreOrchestrator } from '../../../../orchestrator/event-store-orchestrator.js';

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
      },
    };
  });

  describe('getEventHistory', () => {
    it('should return events in reverse chronological order', async () => {
      const mockEvents = [
        { id: 'evt-1', type: 'session.start', timestamp: '2024-01-01T00:00:00Z' },
        { id: 'evt-2', type: 'message.user', timestamp: '2024-01-01T00:01:00Z' },
        { id: 'evt-3', type: 'message.assistant', timestamp: '2024-01-01T00:02:00Z' },
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123');

      expect(mockOrchestrator.events!.getEvents).toHaveBeenCalledWith('sess-123');
      expect(result.events).toHaveLength(3);
      // Should be reversed (most recent first)
      expect(result.events[0].id).toBe('evt-3');
      expect(result.events[2].id).toBe('evt-1');
    });

    it('should filter by event types when specified', async () => {
      const mockEvents = [
        { id: 'evt-1', type: 'session.start' },
        { id: 'evt-2', type: 'message.user' },
        { id: 'evt-3', type: 'message.assistant' },
        { id: 'evt-4', type: 'tool.call' },
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
      const mockEvents = Array.from({ length: 200 }, (_, i) => ({
        id: `evt-${i}`,
        type: 'message.user',
      }));
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getEventHistory('sess-123', { limit: 50 });

      expect(result.events).toHaveLength(50);
      expect(result.hasMore).toBe(true);
    });

    it('should return hasMore false when all events fit', async () => {
      const mockEvents = [
        { id: 'evt-1', type: 'message.user' },
        { id: 'evt-2', type: 'message.assistant' },
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
      const mockEvents = [
        { id: 'evt-1', type: 'session.start' },
        { id: 'evt-2', type: 'message.user' },
        { id: 'evt-3', type: 'message.assistant' },
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
      expect(result.events[0].id).toBe('evt-2');
    });

    it('should return events after specified timestamp', async () => {
      const mockEvents = [
        { id: 'evt-1', type: 'session.start', timestamp: '2024-01-01T00:00:00Z' },
        { id: 'evt-2', type: 'message.user', timestamp: '2024-01-01T00:01:00Z' },
        { id: 'evt-3', type: 'message.assistant', timestamp: '2024-01-01T00:02:00Z' },
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

  describe('getTreeVisualization', () => {
    it('should return tree with node metadata', async () => {
      const mockEvents = [
        { id: 'evt-1', parentId: null, type: 'session.start', timestamp: '2024-01-01T00:00:00Z' },
        { id: 'evt-2', parentId: 'evt-1', type: 'message.user', timestamp: '2024-01-01T00:01:00Z', payload: { content: 'Hello' } },
        { id: 'evt-3', parentId: 'evt-2', type: 'message.assistant', timestamp: '2024-01-01T00:02:00Z' },
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

      // Check node properties
      const rootNode = result.nodes.find((n: any) => n.id === 'evt-1');
      expect(rootNode?.depth).toBe(0);
      expect(rootNode?.hasChildren).toBe(true);
    });

    it('should filter to messages only when requested', async () => {
      const mockEvents = [
        { id: 'evt-1', parentId: null, type: 'session.start', timestamp: '2024-01-01T00:00:00Z' },
        { id: 'evt-2', parentId: 'evt-1', type: 'message.user', timestamp: '2024-01-01T00:01:00Z' },
        { id: 'evt-3', parentId: 'evt-2', type: 'tool.call', timestamp: '2024-01-01T00:02:00Z' },
        { id: 'evt-4', parentId: 'evt-3', type: 'message.assistant', timestamp: '2024-01-01T00:03:00Z' },
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({ rootEventId: 'evt-1', headEventId: 'evt-4' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getTreeVisualization('sess-123', { messagesOnly: true });

      expect(result.nodes).toHaveLength(2); // Only message.* events
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
      const mockEvents = [
        { id: 'evt-1', parentId: null, type: 'session.start' },
        { id: 'evt-2', parentId: 'evt-1', type: 'message.user' },
        { id: 'evt-3', parentId: 'evt-1', type: 'message.user' }, // Branch!
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
      const mockEvents = [
        { id: 'evt-1', parentId: null, type: 'session.start' },
        { id: 'evt-2', parentId: 'evt-1', type: 'message.user' },
      ];
      vi.mocked(mockOrchestrator.events!.getEvents).mockResolvedValue(mockEvents);
      mockEventStore.getSession.mockResolvedValue({ headEventId: 'evt-2' });

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getBranches('sess-123');

      expect(result.mainBranch).toBeDefined();
      expect(result.mainBranch.isMain).toBe(true);
      expect(result.forks).toHaveLength(0);
    });
  });

  describe('getSubtree', () => {
    it('should return ancestors when direction is ancestors', async () => {
      const mockAncestors = [
        { id: 'evt-1', type: 'session.start' },
        { id: 'evt-2', type: 'message.user' },
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
      const mockChildren = [{ id: 'evt-child', type: 'message.user' }];
      mockEventStore.getChildren.mockResolvedValue(mockChildren);

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
      const mockAncestors = [
        { id: 'evt-1', type: 'session.start' },
        { id: 'evt-2', type: 'message.user' },
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
      const mockResults = [
        { id: 'evt-1', type: 'message.user', payload: { content: 'Hello world' } },
      ];
      vi.mocked(mockOrchestrator.events!.search).mockResolvedValue(mockResults);

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
      const mockResult = { id: 'evt-deleted', payload: { targetEventId: 'evt-1' } };
      vi.mocked(mockOrchestrator.events!.deleteMessage).mockResolvedValue(mockResult);

      const adapter = createEventStoreAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.deleteMessage('sess-123', 'evt-1', 'user_request');

      expect(mockOrchestrator.events!.deleteMessage).toHaveBeenCalledWith('sess-123', 'evt-1', 'user_request');
      expect(result).toEqual(mockResult);
    });
  });
});

describe('Helper Functions', () => {
  describe('getEventSummary', () => {
    it('should return appropriate summary for session.start', () => {
      expect(getEventSummary({ type: 'session.start' })).toBe('Session started');
    });

    it('should return appropriate summary for session.end', () => {
      expect(getEventSummary({ type: 'session.end' })).toBe('Session ended');
    });

    it('should return fork name for session.fork', () => {
      expect(getEventSummary({ type: 'session.fork', payload: { name: 'my-fork' } })).toBe('Forked: my-fork');
    });

    it('should truncate user message content', () => {
      const longContent = 'A'.repeat(100);
      expect(getEventSummary({ type: 'message.user', payload: { content: longContent } })).toBe('A'.repeat(50));
    });

    it('should return tool name for tool.call', () => {
      expect(getEventSummary({ type: 'tool.call', payload: { name: 'read_file' } })).toBe('Tool: read_file');
    });

    it('should return type for unknown events', () => {
      expect(getEventSummary({ type: 'custom.event' })).toBe('custom.event');
    });
  });

  describe('getEventDepth', () => {
    it('should return 0 for root event', () => {
      const events = [{ id: 'evt-1', parentId: null }];
      expect(getEventDepth(events[0], events)).toBe(0);
    });

    it('should return correct depth for nested events', () => {
      const events = [
        { id: 'evt-1', parentId: null },
        { id: 'evt-2', parentId: 'evt-1' },
        { id: 'evt-3', parentId: 'evt-2' },
      ];
      expect(getEventDepth(events[2], events)).toBe(2);
    });
  });
});
