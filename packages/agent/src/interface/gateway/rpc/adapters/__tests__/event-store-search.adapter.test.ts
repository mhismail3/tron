/**
 * @fileoverview Tests for Event Store Adapter - Search and Navigation
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createEventStoreAdapter } from '../event-store.adapter.js';
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

describe('EventStoreAdapter - Search & Navigation', () => {
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
