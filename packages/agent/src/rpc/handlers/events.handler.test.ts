/**
 * @fileoverview Tests for Events RPC Handlers
 *
 * Tests events.getHistory, events.getSince, events.append handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createEventsHandlers,
  handleEventsGetHistory,
  handleEventsGetSince,
  handleEventsAppend,
} from './events.handler.js';
import type { RpcRequest } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry } from '../registry.js';

describe('Events Handlers', () => {
  let mockContext: RpcContext;
  let mockContextWithoutEventStore: RpcContext;
  let mockGetEventHistory: ReturnType<typeof vi.fn>;
  let mockGetEventsSince: ReturnType<typeof vi.fn>;
  let mockAppendEvent: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockGetEventHistory = vi.fn().mockResolvedValue({
      events: [
        { id: 'evt-1', type: 'message.user', payload: { content: 'Hello' } },
        { id: 'evt-2', type: 'message.assistant', payload: { content: 'Hi!' } },
      ],
      hasMore: false,
      oldestEventId: 'evt-1',
    });

    mockGetEventsSince = vi.fn().mockResolvedValue({
      events: [
        { id: 'evt-3', type: 'tool.call', payload: { tool: 'bash' } },
      ],
      nextCursor: 'evt-4',
      hasMore: true,
    });

    mockAppendEvent = vi.fn().mockResolvedValue({
      event: { id: 'evt-new', type: 'custom.event', payload: { data: 'test' } },
      newHeadEventId: 'evt-new',
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
      eventStore: {
        getEventHistory: mockGetEventHistory,
        getEventsSince: mockGetEventsSince,
        appendEvent: mockAppendEvent,
        getTreeVisualization: vi.fn(),
        getBranches: vi.fn(),
        getSubtree: vi.fn(),
        getAncestors: vi.fn(),
        searchContent: vi.fn(),
        deleteMessage: vi.fn(),
      } as any,
    };

    mockContextWithoutEventStore = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handleEventsGetHistory', () => {
    it('should get event history for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getHistory',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleEventsGetHistory(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetEventHistory).toHaveBeenCalledWith('sess-123', {
        types: undefined,
        limit: undefined,
        beforeEventId: undefined,
      });
      const result = response.result as { events: any[] };
      expect(result.events).toHaveLength(2);
    });

    it('should pass filter options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getHistory',
        params: {
          sessionId: 'sess-123',
          types: ['message.user', 'message.assistant'],
          limit: 50,
          beforeEventId: 'evt-100',
        },
      };

      const response = await handleEventsGetHistory(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetEventHistory).toHaveBeenCalledWith('sess-123', {
        types: ['message.user', 'message.assistant'],
        limit: 50,
        beforeEventId: 'evt-100',
      });
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getHistory',
        params: {},
      };

      const response = await handleEventsGetHistory(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getHistory',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleEventsGetHistory(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleEventsGetSince', () => {
    it('should get events since a timestamp', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getSince',
        params: { afterTimestamp: '2024-01-15T10:00:00Z' },
      };

      const response = await handleEventsGetSince(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetEventsSince).toHaveBeenCalledWith({
        sessionId: undefined,
        workspaceId: undefined,
        afterEventId: undefined,
        afterTimestamp: '2024-01-15T10:00:00Z',
        limit: undefined,
      });
    });

    it('should filter by session and workspace', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getSince',
        params: {
          sessionId: 'sess-123',
          workspaceId: 'ws-456',
          afterEventId: 'evt-100',
          limit: 20,
        },
      };

      const response = await handleEventsGetSince(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetEventsSince).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        workspaceId: 'ws-456',
        afterEventId: 'evt-100',
        afterTimestamp: undefined,
        limit: 20,
      });
    });

    it('should work with empty params', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getSince',
      };

      const response = await handleEventsGetSince(request, mockContext);

      expect(response.success).toBe(true);
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.getSince',
        params: {},
      };

      const response = await handleEventsGetSince(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleEventsAppend', () => {
    it('should append an event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.append',
        params: {
          sessionId: 'sess-123',
          type: 'custom.event',
          payload: { data: 'test' },
        },
      };

      const response = await handleEventsAppend(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockAppendEvent).toHaveBeenCalledWith(
        'sess-123',
        'custom.event',
        { data: 'test' },
        undefined
      );
    });

    it('should pass parentId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.append',
        params: {
          sessionId: 'sess-123',
          type: 'custom.event',
          payload: { data: 'test' },
          parentId: 'evt-parent',
        },
      };

      const response = await handleEventsAppend(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockAppendEvent).toHaveBeenCalledWith(
        'sess-123',
        'custom.event',
        { data: 'test' },
        'evt-parent'
      );
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.append',
        params: { type: 'custom', payload: {} },
      };

      const response = await handleEventsAppend(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing type', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.append',
        params: { sessionId: 'sess-123', payload: {} },
      };

      const response = await handleEventsAppend(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('type');
    });

    it('should return error for missing payload', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'events.append',
        params: { sessionId: 'sess-123', type: 'custom' },
      };

      const response = await handleEventsAppend(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('payload');
    });
  });

  describe('createEventsHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createEventsHandlers();

      expect(handlers).toHaveLength(3);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('events.getHistory');
      expect(methods).toContain('events.getSince');
      expect(methods).toContain('events.append');
    });

    it('should have eventStore as required for all handlers', () => {
      const handlers = createEventsHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('eventStore');
      }
    });

    it('should have correct options for events.append', () => {
      const handlers = createEventsHandlers();
      const appendHandler = handlers.find(h => h.method === 'events.append');

      expect(appendHandler?.options?.requiredParams).toContain('sessionId');
      expect(appendHandler?.options?.requiredParams).toContain('type');
      expect(appendHandler?.options?.requiredParams).toContain('payload');
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch events handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createEventsHandlers();
      registry.registerAll(handlers);

      expect(registry.has('events.getHistory')).toBe(true);
      expect(registry.has('events.getSince')).toBe(true);
      expect(registry.has('events.append')).toBe(true);

      // Test events.getHistory through registry
      const request: RpcRequest = {
        id: '1',
        method: 'events.getHistory',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('events');
    });
  });
});
