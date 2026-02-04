/**
 * @fileoverview Tests for Event Store Adapter - History Operations
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createEventStoreAdapter } from '../event-store.adapter.js';
import type { EventStoreOrchestrator } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';
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

describe('EventStoreAdapter - History', () => {
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
});
