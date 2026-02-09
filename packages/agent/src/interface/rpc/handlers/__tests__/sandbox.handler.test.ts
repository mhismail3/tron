/**
 * @fileoverview Tests for Sandbox RPC Handlers
 *
 * Tests sandbox.listContainers, sandbox.stopContainer, sandbox.startContainer,
 * and sandbox.killContainer handlers using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSandboxHandlers } from '../sandbox.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Sandbox Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockListContainers: ReturnType<typeof vi.fn>;
  let mockStopContainer: ReturnType<typeof vi.fn>;
  let mockStartContainer: ReturnType<typeof vi.fn>;
  let mockKillContainer: ReturnType<typeof vi.fn>;

  const sampleContainers = [
    {
      name: 'web-app-1',
      image: 'nginx:latest',
      status: 'running',
      ports: ['3000:3000', '8080:80'],
      purpose: 'Web server',
      createdAt: '2025-01-15T10:00:00Z',
      createdBySession: 'sess-1',
      workingDirectory: '/Users/test/project',
    },
    {
      name: 'db-1',
      image: 'postgres:16',
      status: 'stopped',
      ports: ['5432:5432'],
      createdAt: '2025-01-14T10:00:00Z',
      createdBySession: 'sess-2',
      workingDirectory: '/Users/test/project',
    },
  ];

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createSandboxHandlers());

    mockListContainers = vi.fn().mockResolvedValue({
      containers: sampleContainers,
      tailscaleIp: '100.64.1.1',
    });

    mockStopContainer = vi.fn().mockResolvedValue({ success: true });
    mockStartContainer = vi.fn().mockResolvedValue({ success: true });
    mockKillContainer = vi.fn().mockResolvedValue({ success: true });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      sandboxManager: {
        listContainers: mockListContainers,
        stopContainer: mockStopContainer,
        startContainer: mockStartContainer,
        killContainer: mockKillContainer,
      },
    };
  });

  describe('sandbox.listContainers', () => {
    it('should return containers with live statuses', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListContainers).toHaveBeenCalled();
      const result = response.result as { containers: any[]; tailscaleIp?: string };
      expect(result.containers).toHaveLength(2);
      expect(result.tailscaleIp).toBe('100.64.1.1');
    });

    it('should return empty result', async () => {
      mockListContainers.mockResolvedValue({
        containers: [],
        tailscaleIp: undefined,
      });

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { containers: any[]; tailscaleIp?: string };
      expect(result.containers).toEqual([]);
      expect(result.tailscaleIp).toBeUndefined();
    });

    it('should return NOT_AVAILABLE without sandboxManager', async () => {
      const contextWithoutSandbox: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
      };

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
      };

      const response = await registry.dispatch(request, contextWithoutSandbox);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return INTERNAL_ERROR when manager throws', async () => {
      mockListContainers.mockRejectedValue(new Error('CLI not found'));

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INTERNAL_ERROR');
    });

    it('should work with empty/missing params', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListContainers).toHaveBeenCalled();
    });

    it('should pass through result unchanged', async () => {
      const customResult = {
        containers: [sampleContainers[0]],
        tailscaleIp: '100.99.88.77',
      };
      mockListContainers.mockResolvedValue(customResult);

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.listContainers',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(customResult);
    });
  });

  describe('sandbox.stopContainer', () => {
    it('should stop a container by name', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.stopContainer',
        params: { name: 'web-app-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockStopContainer).toHaveBeenCalledWith('web-app-1');
      expect(response.result).toEqual({ success: true });
    });

    it('should return INVALID_PARAMS when name is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.stopContainer',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return INTERNAL_ERROR when manager throws', async () => {
      mockStopContainer.mockRejectedValue(new Error('container stop failed'));

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.stopContainer',
        params: { name: 'web-app-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INTERNAL_ERROR');
    });

    it('should return NOT_AVAILABLE without sandboxManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.stopContainer',
        params: { name: 'web-app-1' },
      };

      const response = await registry.dispatch(request, {
        sessionManager: {} as any,
        agentManager: {} as any,
      });

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('sandbox.startContainer', () => {
    it('should start a container by name', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.startContainer',
        params: { name: 'db-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockStartContainer).toHaveBeenCalledWith('db-1');
      expect(response.result).toEqual({ success: true });
    });

    it('should return INVALID_PARAMS when name is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.startContainer',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return INTERNAL_ERROR when manager throws', async () => {
      mockStartContainer.mockRejectedValue(new Error('container start failed'));

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.startContainer',
        params: { name: 'db-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INTERNAL_ERROR');
    });
  });

  describe('sandbox.killContainer', () => {
    it('should kill a container by name', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.killContainer',
        params: { name: 'web-app-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockKillContainer).toHaveBeenCalledWith('web-app-1');
      expect(response.result).toEqual({ success: true });
    });

    it('should return INVALID_PARAMS when name is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.killContainer',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return INTERNAL_ERROR when manager throws', async () => {
      mockKillContainer.mockRejectedValue(new Error('container kill failed'));

      const request: RpcRequest = {
        id: '1',
        method: 'sandbox.killContainer',
        params: { name: 'web-app-1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INTERNAL_ERROR');
    });
  });

  describe('createSandboxHandlers', () => {
    it('should create 4 handlers for registration', () => {
      const handlers = createSandboxHandlers();

      expect(handlers).toHaveLength(4);
      expect(handlers.map(h => h.method)).toEqual([
        'sandbox.listContainers',
        'sandbox.stopContainer',
        'sandbox.startContainer',
        'sandbox.killContainer',
      ]);
    });

    it('should have sandboxManager as required manager for all handlers', () => {
      const handlers = createSandboxHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('sandboxManager');
      }
    });

    it('should require name param for action handlers', () => {
      const handlers = createSandboxHandlers();

      // listContainers has no required params
      expect(handlers[0].options?.requiredParams).toBeUndefined();

      // stop/start/kill all require name
      for (const handler of handlers.slice(1)) {
        expect(handler.options?.requiredParams).toEqual(['name']);
      }
    });
  });
});
