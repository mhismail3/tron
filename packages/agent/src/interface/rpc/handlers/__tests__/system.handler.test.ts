/**
 * @fileoverview Tests for System RPC Handlers
 *
 * Tests system.ping and system.getInfo handlers using registry dispatch.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { createSystemHandlers } from '../system.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('System Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createSystemHandlers());

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
    };
  });

  describe('system.ping', () => {
    it('should return pong with timestamp', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.error).toBeUndefined();
      expect(response.result).toMatchObject({
        pong: true,
        timestamp: expect.any(String),
      });
    });

    it('should return valid ISO timestamp', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { pong: boolean; timestamp: string };

      // Should be a valid ISO date
      const parsed = new Date(result.timestamp);
      expect(parsed.toISOString()).toBe(result.timestamp);
    });

    it('should preserve request id', async () => {
      const request: RpcRequest = {
        id: 'custom-id-123',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.id).toBe('custom-id-123');
    });
  });

  describe('system.getInfo', () => {
    it('should return system info', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.getInfo',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.error).toBeUndefined();
      expect(response.result).toMatchObject({
        version: expect.any(String),
        uptime: expect.any(Number),
        activeSessions: 0,
        memoryUsage: {
          heapUsed: expect.any(Number),
          heapTotal: expect.any(Number),
        },
      });
    });

    it('should return positive uptime', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.getInfo',
      };

      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { uptime: number };

      expect(result.uptime).toBeGreaterThanOrEqual(0);
    });

    it('should return valid memory stats', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.getInfo',
      };

      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { memoryUsage: { heapUsed: number; heapTotal: number } };

      expect(result.memoryUsage.heapUsed).toBeGreaterThan(0);
      expect(result.memoryUsage.heapTotal).toBeGreaterThan(0);
      expect(result.memoryUsage.heapUsed).toBeLessThanOrEqual(result.memoryUsage.heapTotal);
    });
  });

  describe('createSystemHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createSystemHandlers();

      expect(handlers).toHaveLength(2);
      expect(handlers[0]?.method).toBe('system.ping');
      expect(handlers[1]?.method).toBe('system.getInfo');
    });

    it('should return working handler functions', async () => {
      const handlers = createSystemHandlers();
      const pingHandler = handlers.find((h) => h.method === 'system.ping');

      const request: RpcRequest = {
        id: '1',
        method: 'system.ping',
      };

      const result = await pingHandler!.handler(request, mockContext);
      expect(result).toMatchObject({ pong: true });
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch system handlers', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.result).toMatchObject({ pong: true });
    });

    it('should list system namespace methods', () => {
      const systemMethods = registry.listByNamespace('system');
      expect(systemMethods).toContain('system.ping');
      expect(systemMethods).toContain('system.getInfo');
    });
  });
});
