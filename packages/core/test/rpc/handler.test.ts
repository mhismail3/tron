/**
 * @fileoverview Tests for RPC handler
 *
 * TDD: Tests for request handling and dispatching
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { RpcHandler, type RpcContext } from '../../src/rpc/handler.js';
import type { RpcRequest, RpcResponse, RpcEvent } from '../../src/rpc/types.js';

describe('RpcHandler', () => {
  let handler: RpcHandler;
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      sessionManager: {
        createSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_123',
          model: 'claude-sonnet-4-20250514',
          createdAt: new Date().toISOString(),
        }),
        getSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_123',
          messages: [],
          workingDirectory: '/test',
        }),
        listSessions: vi.fn().mockResolvedValue([]),
        deleteSession: vi.fn().mockResolvedValue(true),
        forkSession: vi.fn().mockResolvedValue({
          newSessionId: 'sess_456',
          forkedFrom: 'sess_123',
          messageCount: 5,
        }),
      },
      agentManager: {
        prompt: vi.fn().mockResolvedValue({ acknowledged: true }),
        abort: vi.fn().mockResolvedValue({ aborted: true }),
        getState: vi.fn().mockResolvedValue({
          isRunning: false,
          currentTurn: 0,
          messageCount: 5,
          tokenUsage: { input: 1000, output: 500 },
          model: 'claude-sonnet-4-20250514',
          tools: ['read', 'write', 'edit', 'bash'],
        }),
      },
      memoryStore: {
        searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
        addEntry: vi.fn().mockResolvedValue({ id: 'mem_123' }),
        listHandoffs: vi.fn().mockResolvedValue([]),
      },
    } as unknown as RpcContext;

    handler = new RpcHandler(mockContext);
  });

  describe('constructor', () => {
    it('should create handler with context', () => {
      expect(handler).toBeInstanceOf(RpcHandler);
    });
  });

  describe('handle', () => {
    it('should handle session.create request', async () => {
      const request: RpcRequest = {
        id: 'req_1',
        method: 'session.create',
        params: {
          workingDirectory: '/test/project',
        },
      };

      const response = await handler.handle(request);

      expect(response.id).toBe('req_1');
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('sessionId');
    });

    it('should handle session.list request', async () => {
      const request: RpcRequest = {
        id: 'req_2',
        method: 'session.list',
        params: {
          limit: 10,
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('sessions');
    });

    it('should handle agent.prompt request', async () => {
      const request: RpcRequest = {
        id: 'req_3',
        method: 'agent.prompt',
        params: {
          sessionId: 'sess_123',
          prompt: 'Hello agent',
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('acknowledged', true);
    });

    it('should handle agent.abort request', async () => {
      const request: RpcRequest = {
        id: 'req_4',
        method: 'agent.abort',
        params: {
          sessionId: 'sess_123',
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('aborted');
    });

    it('should handle agent.getState request', async () => {
      const request: RpcRequest = {
        id: 'req_5',
        method: 'agent.getState',
        params: {
          sessionId: 'sess_123',
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('isRunning');
      expect(response.result).toHaveProperty('tokenUsage');
    });

    it('should handle system.ping request', async () => {
      const request: RpcRequest = {
        id: 'req_6',
        method: 'system.ping',
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('pong', true);
      expect(response.result).toHaveProperty('timestamp');
    });

    it('should handle system.getInfo request', async () => {
      const request: RpcRequest = {
        id: 'req_7',
        method: 'system.getInfo',
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('version');
      expect(response.result).toHaveProperty('uptime');
    });

    it('should return error for unknown method', async () => {
      const request: RpcRequest = {
        id: 'req_8',
        method: 'unknown.method',
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('METHOD_NOT_FOUND');
    });

    it('should return error for missing required params', async () => {
      const request: RpcRequest = {
        id: 'req_9',
        method: 'session.create',
        // Missing workingDirectory
        params: {},
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should handle memory.search request', async () => {
      const request: RpcRequest = {
        id: 'req_10',
        method: 'memory.search',
        params: {
          searchText: 'test pattern',
          type: 'pattern',
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('entries');
    });

    it('should handle session.fork request', async () => {
      const request: RpcRequest = {
        id: 'req_11',
        method: 'session.fork',
        params: {
          sessionId: 'sess_123',
        },
      };

      const response = await handler.handle(request);

      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('newSessionId');
    });
  });

  describe('error handling', () => {
    it('should catch and wrap handler errors', async () => {
      // Create a fresh handler with a failing session manager
      const failingContext = {
        ...mockContext,
        sessionManager: {
          ...mockContext.sessionManager,
          createSession: vi.fn().mockRejectedValue(
            new Error('Database connection failed')
          ),
        },
      } as unknown as RpcContext;

      const failingHandler = new RpcHandler(failingContext);

      const request: RpcRequest = {
        id: 'req_err',
        method: 'session.create',
        params: {
          workingDirectory: '/test',
        },
      };

      const response = await failingHandler.handle(request);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INTERNAL_ERROR');
      expect(response.error?.message).toContain('Database connection failed');
    });
  });

  describe('event emission', () => {
    it('should allow registering event listeners', () => {
      const listener = vi.fn();
      handler.on('event', listener);

      handler.emitEvent({
        type: 'agent.text_delta',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: { delta: 'Hello' },
      });

      expect(listener).toHaveBeenCalledTimes(1);
    });

    it('should remove event listeners', () => {
      const listener = vi.fn();
      handler.on('event', listener);
      handler.off('event', listener);

      handler.emitEvent({
        type: 'test',
        timestamp: new Date().toISOString(),
        data: {},
      });

      expect(listener).not.toHaveBeenCalled();
    });
  });

  describe('middleware', () => {
    it('should allow registering middleware', async () => {
      const middleware = vi.fn((req, next) => next(req));
      handler.use(middleware);

      const request: RpcRequest = {
        id: 'req_mid',
        method: 'system.ping',
      };

      await handler.handle(request);

      expect(middleware).toHaveBeenCalled();
    });

    it('should execute middleware in order', async () => {
      const order: number[] = [];

      handler.use(async (req, next) => {
        order.push(1);
        const result = await next(req);
        order.push(4);
        return result;
      });

      handler.use(async (req, next) => {
        order.push(2);
        const result = await next(req);
        order.push(3);
        return result;
      });

      await handler.handle({
        id: 'req_ord',
        method: 'system.ping',
      });

      expect(order).toEqual([1, 2, 3, 4]);
    });

    it('should allow middleware to short-circuit', async () => {
      handler.use(async (req, next) => {
        return {
          id: req.id,
          success: false,
          error: { code: 'BLOCKED', message: 'Request blocked' },
        };
      });

      const response = await handler.handle({
        id: 'req_block',
        method: 'system.ping',
      });

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BLOCKED');
    });
  });
});
