/**
 * @fileoverview Tests for query-handler
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest';
import { QueryHandler, createQueryHandler } from '../query-handler.js';
import type { EventStore } from '../../../../events/event-store.js';
import type { ActiveSession } from '../../../types.js';

describe('QueryHandler', () => {
  let getSession: Mock;
  let getAncestors: Mock;
  let getLogsForSession: Mock;
  let getActiveSession: Mock;
  let handler: QueryHandler;

  beforeEach(() => {
    getSession = vi.fn();
    getAncestors = vi.fn();
    getLogsForSession = vi.fn();
    getActiveSession = vi.fn();

    const mockEventStore = {
      getSession,
      getAncestors,
      getLogsForSession,
    } as unknown as EventStore;

    handler = createQueryHandler({
      eventStore: mockEventStore,
      getActiveSession,
    });
  });

  describe('querySubagent - status', () => {
    it('should return error when session not found', async () => {
      getSession.mockResolvedValue(null);

      const result = await handler.querySubagent('sess_notfound', 'status');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Session not found');
    });

    it('should return running status for active session', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        endedAt: null,
        spawnType: 'subsession',
        spawnTask: 'Test task',
        turnCount: 3,
        totalInputTokens: 1000,
        totalOutputTokens: 500,
        totalCost: 0.01,
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:01:00Z',
        latestModel: 'claude-3-sonnet',
        workingDirectory: '/test',
      });
      getActiveSession.mockReturnValue({} as ActiveSession);

      const result = await handler.querySubagent('sess_123', 'status');

      expect(result.success).toBe(true);
      expect(result.status?.status).toBe('running');
      expect(result.status?.sessionId).toBe('sess_123');
      expect(result.status?.turnCount).toBe(3);
    });

    it('should return completed status for ended session without errors', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        headEventId: 'evt_head',
        endedAt: '2024-01-01T00:02:00Z',
        spawnType: 'subsession',
        spawnTask: 'Test task',
        turnCount: 5,
      });
      getActiveSession.mockReturnValue(undefined);
      getAncestors.mockResolvedValue([
        { id: 'evt_1', type: 'message.user', timestamp: '', payload: {} },
        { id: 'evt_2', type: 'message.assistant', timestamp: '', payload: {} },
      ]);

      const result = await handler.querySubagent('sess_123', 'status');

      expect(result.success).toBe(true);
      expect(result.status?.status).toBe('completed');
    });

    it('should return failed status for ended session with error event', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        headEventId: 'evt_head',
        endedAt: '2024-01-01T00:02:00Z',
        spawnType: 'subsession',
        spawnTask: 'Test task',
        turnCount: 2,
      });
      getActiveSession.mockReturnValue(undefined);
      getAncestors.mockResolvedValue([
        { id: 'evt_1', type: 'message.user', timestamp: '', payload: {} },
        { id: 'evt_2', type: 'error.agent', timestamp: '', payload: {} },
      ]);

      const result = await handler.querySubagent('sess_123', 'status');

      expect(result.success).toBe(true);
      expect(result.status?.status).toBe('failed');
    });
  });

  describe('querySubagent - events', () => {
    it('should return recent events', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        headEventId: 'evt_head',
      });
      getAncestors.mockResolvedValue([
        { id: 'evt_1', type: 'session.start', timestamp: '2024-01-01T00:00:00Z', payload: {} },
        { id: 'evt_2', type: 'message.user', timestamp: '2024-01-01T00:00:01Z', payload: { content: 'Hello world' } },
        { id: 'evt_3', type: 'message.assistant', timestamp: '2024-01-01T00:00:02Z', payload: { turn: 1 } },
      ]);

      const result = await handler.querySubagent('sess_123', 'events', 10);

      expect(result.success).toBe(true);
      expect(result.events).toHaveLength(3);
      expect(result.events![0].type).toBe('message.assistant');
      expect(result.events![0].summary).toContain('Assistant response');
    });
  });

  describe('querySubagent - logs', () => {
    it('should return session logs', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
      });
      getLogsForSession.mockResolvedValue([
        { timestamp: '2024-01-01T00:00:00Z', level: 'info', component: 'agent', message: 'Started' },
        { timestamp: '2024-01-01T00:00:01Z', level: 'error', component: 'tool', message: 'Failed' },
      ]);

      const result = await handler.querySubagent('sess_123', 'logs', 10);

      expect(result.success).toBe(true);
      expect(result.logs).toHaveLength(2);
      expect(result.logs![0].level).toBe('info');
      expect(result.logs![1].level).toBe('error');
    });
  });

  describe('querySubagent - output', () => {
    it('should return last assistant message text', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        headEventId: 'evt_head',
      });
      getAncestors.mockResolvedValue([
        { id: 'evt_1', type: 'message.user', timestamp: '', payload: {} },
        {
          id: 'evt_2',
          type: 'message.assistant',
          timestamp: '',
          payload: {
            content: [
              { type: 'text', text: 'Hello' },
              { type: 'text', text: 'World' },
            ],
          },
        },
      ]);

      const result = await handler.querySubagent('sess_123', 'output');

      expect(result.success).toBe(true);
      expect(result.output).toBe('Hello\nWorld');
    });

    it('should return undefined when no assistant message', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
        headEventId: 'evt_head',
      });
      getAncestors.mockResolvedValue([
        { id: 'evt_1', type: 'message.user', timestamp: '', payload: {} },
      ]);

      const result = await handler.querySubagent('sess_123', 'output');

      expect(result.success).toBe(true);
      expect(result.output).toBeUndefined();
    });
  });

  describe('querySubagent - unknown type', () => {
    it('should return error for unknown query type', async () => {
      getSession.mockResolvedValue({
        id: 'sess_123',
      });

      const result = await handler.querySubagent('sess_123', 'invalid' as any);

      expect(result.success).toBe(false);
      expect(result.error).toContain('Unknown query type');
    });
  });

  describe('error handling', () => {
    it('should handle errors gracefully', async () => {
      getSession.mockRejectedValue(new Error('DB error'));

      const result = await handler.querySubagent('sess_123', 'status');

      expect(result.success).toBe(false);
      expect(result.error).toBe('DB error');
    });
  });
});
