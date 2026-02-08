/**
 * @fileoverview Tests for Sandbox RPC Handlers
 *
 * Tests sandbox.listContainers handler using the registry dispatch pattern.
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

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      sandboxManager: {
        listContainers: mockListContainers,
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

  describe('createSandboxHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createSandboxHandlers();

      expect(handlers).toHaveLength(1);
      expect(handlers[0].method).toBe('sandbox.listContainers');
    });

    it('should have sandboxManager as required manager', () => {
      const handlers = createSandboxHandlers();

      expect(handlers[0].options?.requiredManagers).toContain('sandboxManager');
    });

    it('should not require any params', () => {
      const handlers = createSandboxHandlers();

      expect(handlers[0].options?.requiredParams).toBeUndefined();
    });
  });
});
