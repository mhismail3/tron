/**
 * @fileoverview Tests for Tree RPC Handlers
 *
 * Tests tree.getVisualization, tree.getBranches, tree.getSubtree, tree.getAncestors handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createTreeHandlers,
  handleTreeGetVisualization,
  handleTreeGetBranches,
  handleTreeGetSubtree,
  handleTreeGetAncestors,
} from '../tree.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Tree Handlers', () => {
  let mockContext: RpcContext;
  let mockContextWithoutEventStore: RpcContext;
  let mockGetTreeVisualization: ReturnType<typeof vi.fn>;
  let mockGetBranches: ReturnType<typeof vi.fn>;
  let mockGetSubtree: ReturnType<typeof vi.fn>;
  let mockGetAncestors: ReturnType<typeof vi.fn>;

  beforeEach(() => {
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
      memoryStore: {} as any,
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
      memoryStore: {} as any,
    };
  });

  describe('handleTreeGetVisualization', () => {
    it('should get tree visualization for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleTreeGetVisualization(request, mockContext);

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

      const response = await handleTreeGetVisualization(request, mockContext);

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

      const response = await handleTreeGetVisualization(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getVisualization',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleTreeGetVisualization(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleTreeGetBranches', () => {
    it('should get branches for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleTreeGetBranches(request, mockContext);

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

      const response = await handleTreeGetBranches(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleTreeGetBranches(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleTreeGetSubtree', () => {
    it('should get subtree from an event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: { eventId: 'evt-123' },
      };

      const response = await handleTreeGetSubtree(request, mockContext);

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

      const response = await handleTreeGetSubtree(request, mockContext);

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

      const response = await handleTreeGetSubtree(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('eventId');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getSubtree',
        params: { eventId: 'evt-123' },
      };

      const response = await handleTreeGetSubtree(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleTreeGetAncestors', () => {
    it('should get ancestors of an event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getAncestors',
        params: { eventId: 'evt-123' },
      };

      const response = await handleTreeGetAncestors(request, mockContext);

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

      const response = await handleTreeGetAncestors(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('eventId');
    });

    it('should return NOT_SUPPORTED without eventStore', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getAncestors',
        params: { eventId: 'evt-123' },
      };

      const response = await handleTreeGetAncestors(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
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

  describe('Registry Integration', () => {
    it('should register and dispatch tree handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createTreeHandlers();
      registry.registerAll(handlers);

      expect(registry.has('tree.getVisualization')).toBe(true);
      expect(registry.has('tree.getBranches')).toBe(true);
      expect(registry.has('tree.getSubtree')).toBe(true);
      expect(registry.has('tree.getAncestors')).toBe(true);

      // Test tree.getBranches through registry
      const request: RpcRequest = {
        id: '1',
        method: 'tree.getBranches',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('mainBranch');
    });
  });
});
