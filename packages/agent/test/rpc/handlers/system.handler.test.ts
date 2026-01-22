/**
 * @fileoverview Tests for System RPC Handlers
 *
 * Tests system.ping and system.getInfo handlers in isolation.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createSystemHandlers,
  handleSystemPing,
  handleSystemGetInfo,
} from '../../../src/rpc/handlers/system.handler.js';
import type { RpcRequest } from '../../../src/rpc/types.js';
import type { RpcContext } from '../../../src/rpc/handler.js';
import { MethodRegistry } from '../../../src/rpc/registry.js';

describe('System Handlers', () => {
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handleSystemPing', () => {
    it('should return pong with timestamp', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.ping',
      };

      const response = await handleSystemPing(request, mockContext);

      expect(response.error).toBeUndefined();
      expect(response.result).toMatchObject({
        pong: true,
        timestamp: expect.any(String),
      });
    });

    it('should return valid ISO timestamp', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.ping',
      };

      const response = await handleSystemPing(request, mockContext);
      const result = response.result as { pong: boolean; timestamp: string };

      // Should be a valid ISO date
      const parsed = new Date(result.timestamp);
      expect(parsed.toISOString()).toBe(result.timestamp);
    });

    it('should preserve request id', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: 'custom-id-123',
        method: 'system.ping',
      };

      const response = await handleSystemPing(request, mockContext);

      expect(response.id).toBe('custom-id-123');
    });
  });

  describe('handleSystemGetInfo', () => {
    it('should return system info', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.getInfo',
      };

      const response = await handleSystemGetInfo(request, mockContext);

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
        jsonrpc: '2.0',
        id: '1',
        method: 'system.getInfo',
      };

      const response = await handleSystemGetInfo(request, mockContext);
      const result = response.result as { uptime: number };

      expect(result.uptime).toBeGreaterThanOrEqual(0);
    });

    it('should return valid memory stats', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.getInfo',
      };

      const response = await handleSystemGetInfo(request, mockContext);
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
        jsonrpc: '2.0',
        id: '1',
        method: 'system.ping',
      };

      const result = await pingHandler!.handler(request, mockContext);
      expect(result).toMatchObject({ pong: true });
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch system handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createSystemHandlers();
      registry.registerAll(handlers);

      expect(registry.has('system.ping')).toBe(true);
      expect(registry.has('system.getInfo')).toBe(true);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.result).toMatchObject({ pong: true });
    });

    it('should list system namespace methods', () => {
      const registry = new MethodRegistry();
      const handlers = createSystemHandlers();
      registry.registerAll(handlers);

      const systemMethods = registry.listByNamespace('system');
      expect(systemMethods).toContain('system.ping');
      expect(systemMethods).toContain('system.getInfo');
    });
  });
});
