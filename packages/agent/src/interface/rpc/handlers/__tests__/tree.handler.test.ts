/**
 * @fileoverview Tests for Tree RPC Handlers
 *
 * Tests tree.getVisualization, tree.getBranches, tree.getSubtree, tree.getAncestors handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createTreeHandlers } from '../tree.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Tree Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutEventStore: RpcContext;
  let mockGetTreeVisualization: ReturnType<typeof vi.fn>;
  let mockGetBranches: ReturnType<typeof vi.fn>;
  let mockGetSubtree: ReturnType<typeof vi.fn>;
  let mockGetAncestors: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createTreeHandlers());

    mockGetTreeVisualization = vi.fn().mockResolvedValue({
      sessionId: 'sess-123',
      rootEventId: 'evt-root',
      headEventId: 'evt-head',
      nodes: [
        { id: 'evt-1', type: 'message.user', children: ['evt-2'] },
        { id: 'evt-2', type: 'message.assistant', children: [] },
      ],
      totalEvents: 2,
    });

    mockGetBranches = vi.fn().mockResolvedValue({
      mainBranch: { headEventId: 'evt-head', events: ['evt-1', 'evt-2'] },
      forks: [
        { branchId: 'branch-1', headEventId: 'evt-fork-1', forkPoint: 'evt-1' },
      ],
    });

    mockGetSubtree = vi.fn().mockResolvedValue({
      nodes: [
        { id: 'evt-1', children: ['evt-2', 'evt-3'] },
        { id: 'evt-2', children: [] },
        { id: 'evt-3', children: [] },
      ],
    });

    mockGetAncestors = vi.fn().mockResolvedValue({
      events: [
        { id: 'evt-root', type: 'session.created' },
        { id: 'evt-1', type: 'message.user' },
        { id: 'evt-2', type: 'message.assistant' },
      ],
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      eventStore: {
        getEventHistory: vi.fn(),
        getEventsSince: vi.fn(),
        appendEvent: vi.fn(),
        getTreeVisualization: mockGetTreeVisualization,
        getBranches: mockGetBranches,
        getSubtree: mockGetSubtree,
        getAncestors: mockGetAncestors,
        searchContent: vi.fn(),
        deleteMessage: vi.fn(),
      } as any,
    };

    mockContextWithoutEventStore = {
      sessionManager: {} as any,
      agentManager: {} as any,
    };
  });

  describe('tree.getVisualization', () => {
    it('should get tree visualization for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetTreeVisualization).toHaveBeenCalledWith('sess-123', {
        maxDepth: undefined,
        messagesOnly: undefined,
      });
      const result = response.result as { nodes: any[] };
      expect(result.nodes).toHaveLength(2);
    });

    it('should pass options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: {
          sessionId: 'sess-123',
          maxDepth: 10,
          messagesOnly: true,
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetTreeVisualization).toHaveBeenCalledWith('sess-123', {
        maxDepth: 10,
        messagesOnly: true,
      });
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_AVAILABLE without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('tree.getBranches', () => {
    it('should get branches for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetBranches).toHaveBeenCalledWith('sess-123');
      const result = response.result as { mainBranch: any; forks: any[] };
      expect(result.mainBranch).toBeDefined();
      expect(result.forks).toHaveLength(1);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return NOT_AVAILABLE without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('tree.getSubtree', () => {
    it('should get subtree from an event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: { eventId: 'evt-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetSubtree).toHaveBeenCalledWith('evt-123', {
        maxDepth: undefined,
        direction: undefined,
      });
      const result = response.result as { nodes: any[] };
      expect(result.nodes).toHaveLength(3);
    });

    it('should pass options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: {
          eventId: 'evt-123',
          maxDepth: 5,
          direction: 'ancestors',
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetSubtree).toHaveBeenCalledWith('evt-123', {
        maxDepth: 5,
        direction: 'ancestors',
      });
    });

    it('should return error for missing eventId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('eventId');
    });

    it('should return NOT_AVAILABLE without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: { eventId: 'evt-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('tree.getAncestors', () => {
    it('should get ancestors of an event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getAncestors',
        params: { eventId: 'evt-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetAncestors).toHaveBeenCalledWith('evt-123');
      const result = response.result as { events: any[] };
      expect(result.events).toHaveLength(3);
    });

    it('should return error for missing eventId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getAncestors',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('eventId');
    });

    it('should return NOT_AVAILABLE without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getAncestors',
        params: { eventId: 'evt-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('createTreeHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createTreeHandlers();

      expect(handlers).toHaveLength(4);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('tree.getVisualization');
      expect(methods).toContain('tree.getBranches');
      expect(methods).toContain('tree.getSubtree');
      expect(methods).toContain('tree.getAncestors');
    });

    it('should have eventStore as required for all handlers', () => {
      const handlers = createTreeHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('eventStore');
      }
    });

    it('should have correct required params', () => {
      const handlers = createTreeHandlers();

      const vizHandler = handlers.find(h => h.method === 'tree.getVisualization');
      expect(vizHandler?.options?.requiredParams).toContain('sessionId');

      const subtreeHandler = handlers.find(h => h.method === 'tree.getSubtree');
      expect(subtreeHandler?.options?.requiredParams).toContain('eventId');

      const ancestorsHandler = handlers.find(h => h.method === 'tree.getAncestors');
      expect(ancestorsHandler?.options?.requiredParams).toContain('eventId');
    });
  });
});
