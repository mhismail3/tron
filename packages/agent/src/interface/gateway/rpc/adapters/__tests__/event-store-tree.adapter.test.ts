/**
 * @fileoverview Tests for Event Store Adapter - Tree Visualization & Branches
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

describe('EventStoreAdapter - Tree Operations', () => {
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
});
