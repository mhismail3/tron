/**
 * @fileoverview Tests for Search RPC Handlers
 *
 * Tests search.content and search.events handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createSearchHandlers,
  handleSearchContent,
  handleSearchEvents,
} from './search.handler.js';
import type { RpcRequest } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry } from '../registry.js';

describe('Search Handlers', () => {
  let mockContext: RpcContext;
  let mockContextWithoutEventStore: RpcContext;
  let mockSearchContent: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSearchContent = vi.fn().mockResolvedValue({
      results: [
        { eventId: 'evt-1', content: 'Hello world', score: 0.95 },
        { eventId: 'evt-2', content: 'Hello again', score: 0.85 },
      ],
      totalCount: 2,
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
      eventStore: {
        searchContent: mockSearchContent,
        getEventHistory: vi.fn(),
        getEventsSince: vi.fn(),
        appendEvent: vi.fn(),
        getTreeVisualization: vi.fn(),
        getBranches: vi.fn(),
        getSubtree: vi.fn(),
        getAncestors: vi.fn(),
        deleteMessage: vi.fn(),
      } as any,
    };

    mockContextWithoutEventStore = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handleSearchContent', () => {
    it('should search content', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.content',
        params: { query: 'hello' },
      };

      const response = await handleSearchContent(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSearchContent).toHaveBeenCalledWith('hello', {
        sessionId: undefined,
        workspaceId: undefined,
        types: undefined,
        limit: undefined,
      });
      const result = response.result as { results: any[] };
      expect(result.results).toHaveLength(2);
    });

    it('should pass filter options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.content',
        params: {
          query: 'test',
          sessionId: 'sess-123',
          workspaceId: 'ws-456',
          types: ['message.user'],
          limit: 20,
        },
      };

      const response = await handleSearchContent(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSearchContent).toHaveBeenCalledWith('test', {
        sessionId: 'sess-123',
        workspaceId: 'ws-456',
        types: ['message.user'],
        limit: 20,
      });
    });

    it('should return error for missing query', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.content',
        params: {},
      };

      const response = await handleSearchContent(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('query');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.content',
        params: { query: 'test' },
      };

      const response = await handleSearchContent(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleSearchEvents', () => {
    it('should search events', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.events',
        params: { query: 'hello' },
      };

      const response = await handleSearchEvents(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSearchContent).toHaveBeenCalledWith('hello', {
        sessionId: undefined,
        workspaceId: undefined,
        types: undefined,
        limit: undefined,
      });
    });

    it('should return error for missing query', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.events',
        params: {},
      };

      const response = await handleSearchEvents(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'search.events',
        params: { query: 'test' },
      };

      const response = await handleSearchEvents(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('createSearchHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createSearchHandlers();

      expect(handlers).toHaveLength(2);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('search.content');
      expect(methods).toContain('search.events');
    });

    it('should have eventStore as required for all handlers', () => {
      const handlers = createSearchHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('eventStore');
      }
    });

    it('should require query param for all handlers', () => {
      const handlers = createSearchHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredParams).toContain('query');
      }
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch search handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createSearchHandlers();
      registry.registerAll(handlers);

      expect(registry.has('search.content')).toBe(true);
      expect(registry.has('search.events')).toBe(true);

      // Test search.content through registry
      const request: RpcRequest = {
        id: '1',
        method: 'search.content',
        params: { query: 'test' },
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('results');
    });
  });
});
