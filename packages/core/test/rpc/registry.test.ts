/**
 * @fileoverview Tests for RPC Method Registry
 *
 * Tests the registration and dispatch system for RPC method handlers.
 * Uses TDD approach - these tests define the expected behavior.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  MethodRegistry,
  type MethodHandler,
  type MethodRegistration,
  type HandlerContext,
} from '../../src/rpc/registry.js';
import type { RpcRequest, RpcResponse } from '../../src/rpc/types.js';

describe('MethodRegistry', () => {
  let registry: MethodRegistry;
  let mockContext: HandlerContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('registration', () => {
    it('should register a method handler', () => {
      const handler: MethodHandler = vi.fn().mockResolvedValue({ result: 'ok' });

      registry.register('system.ping', handler);

      expect(registry.has('system.ping')).toBe(true);
    });

    it('should register a method with options', () => {
      const handler: MethodHandler = vi.fn();

      registry.register('session.create', handler, {
        requiredParams: ['workingDirectory'],
        requiredManagers: ['sessionManager'],
      });

      const registration = registry.get('session.create');
      expect(registration).toBeDefined();
      expect(registration?.options?.requiredParams).toContain('workingDirectory');
      expect(registration?.options?.requiredManagers).toContain('sessionManager');
    });

    it('should throw when registering duplicate method', () => {
      const handler: MethodHandler = vi.fn();
      registry.register('system.ping', handler);

      expect(() => registry.register('system.ping', handler)).toThrow(
        'Method "system.ping" is already registered'
      );
    });

    it('should allow overwriting with force option', () => {
      const handler1: MethodHandler = vi.fn();
      const handler2: MethodHandler = vi.fn();

      registry.register('system.ping', handler1);
      registry.register('system.ping', handler2, { force: true });

      expect(registry.get('system.ping')?.handler).toBe(handler2);
    });

    it('should list all registered methods', () => {
      registry.register('system.ping', vi.fn());
      registry.register('system.getInfo', vi.fn());
      registry.register('session.create', vi.fn());

      const methods = registry.list();
      expect(methods).toContain('system.ping');
      expect(methods).toContain('system.getInfo');
      expect(methods).toContain('session.create');
      expect(methods).toHaveLength(3);
    });

    it('should list methods by namespace', () => {
      registry.register('system.ping', vi.fn());
      registry.register('system.getInfo', vi.fn());
      registry.register('session.create', vi.fn());
      registry.register('session.list', vi.fn());

      expect(registry.listByNamespace('system')).toEqual(['system.ping', 'system.getInfo']);
      expect(registry.listByNamespace('session')).toEqual(['session.create', 'session.list']);
      expect(registry.listByNamespace('unknown')).toEqual([]);
    });
  });

  describe('dispatch', () => {
    it('should dispatch to registered handler', async () => {
      const handler: MethodHandler = vi.fn().mockResolvedValue({ pong: true });
      registry.register('system.ping', handler);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(handler).toHaveBeenCalledWith(request, mockContext);
      expect(response.result).toEqual({ pong: true });
      expect(response.error).toBeUndefined();
    });

    it('should return METHOD_NOT_FOUND for unregistered method', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'unknown.method',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.error?.code).toBe('METHOD_NOT_FOUND');
      expect(response.error?.message).toContain('unknown.method');
    });

    it('should validate required params', async () => {
      const handler: MethodHandler = vi.fn();
      registry.register('session.create', handler, {
        requiredParams: ['workingDirectory'],
      });

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: {}, // Missing workingDirectory
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('workingDirectory');
      expect(handler).not.toHaveBeenCalled();
    });

    it('should validate required managers', async () => {
      const handler: MethodHandler = vi.fn();
      registry.register('transcribe.audio', handler, {
        requiredManagers: ['transcriptionManager'],
      });

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'transcribe.audio',
        params: { audioData: 'base64...' },
      };

      // Context without transcriptionManager
      const response = await registry.dispatch(request, mockContext);

      expect(response.error?.code).toBe('NOT_AVAILABLE');
      expect(response.error?.message).toContain('transcriptionManager');
      expect(handler).not.toHaveBeenCalled();
    });

    it('should pass validation when manager exists', async () => {
      const handler: MethodHandler = vi.fn().mockResolvedValue({ ok: true });
      registry.register('transcribe.audio', handler, {
        requiredManagers: ['transcriptionManager'],
      });

      const contextWithTranscription: HandlerContext = {
        ...mockContext,
        transcriptionManager: {} as any,
      };

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'transcribe.audio',
        params: { audioData: 'base64...' },
      };

      const response = await registry.dispatch(request, contextWithTranscription);

      expect(response.error).toBeUndefined();
      expect(handler).toHaveBeenCalled();
    });

    it('should catch and wrap handler errors', async () => {
      const handler: MethodHandler = vi.fn().mockRejectedValue(new Error('Something broke'));
      registry.register('session.create', handler);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: { workingDirectory: '/test' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.error?.code).toBe('INTERNAL_ERROR');
      expect(response.error?.message).toContain('Something broke');
    });

    it('should preserve request id in response', async () => {
      const handler: MethodHandler = vi.fn().mockResolvedValue({});
      registry.register('system.ping', handler);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: 'my-custom-id-123',
        method: 'system.ping',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.id).toBe('my-custom-id-123');
    });
  });

  describe('bulk registration', () => {
    it('should register multiple methods at once', () => {
      const handlers: MethodRegistration[] = [
        { method: 'system.ping', handler: vi.fn() },
        { method: 'system.getInfo', handler: vi.fn() },
        { method: 'session.create', handler: vi.fn(), options: { requiredParams: ['workingDirectory'] } },
      ];

      registry.registerAll(handlers);

      expect(registry.has('system.ping')).toBe(true);
      expect(registry.has('system.getInfo')).toBe(true);
      expect(registry.has('session.create')).toBe(true);
    });
  });

  describe('unregistration', () => {
    it('should unregister a method', () => {
      const handler: MethodHandler = vi.fn();
      registry.register('system.ping', handler);
      expect(registry.has('system.ping')).toBe(true);

      const removed = registry.unregister('system.ping');

      expect(removed).toBe(true);
      expect(registry.has('system.ping')).toBe(false);
    });

    it('should return false when unregistering non-existent method', () => {
      const removed = registry.unregister('unknown.method');
      expect(removed).toBe(false);
    });

    it('should clear all registrations', () => {
      registry.register('system.ping', vi.fn());
      registry.register('system.getInfo', vi.fn());

      registry.clear();

      expect(registry.list()).toHaveLength(0);
    });
  });

  describe('response helpers', () => {
    it('should create success response', () => {
      const response = MethodRegistry.successResponse('req-1', { foo: 'bar' });

      expect(response).toEqual({
        jsonrpc: '2.0',
        id: 'req-1',
        result: { foo: 'bar' },
      });
    });

    it('should create error response', () => {
      const response = MethodRegistry.errorResponse('req-1', 'INVALID_PARAMS', 'Missing field');

      expect(response).toEqual({
        jsonrpc: '2.0',
        id: 'req-1',
        error: {
          code: 'INVALID_PARAMS',
          message: 'Missing field',
        },
      });
    });

    it('should create error response with data', () => {
      const response = MethodRegistry.errorResponse('req-1', 'VALIDATION_ERROR', 'Invalid input', {
        field: 'email',
        reason: 'format',
      });

      expect(response).toEqual({
        jsonrpc: '2.0',
        id: 'req-1',
        error: {
          code: 'VALIDATION_ERROR',
          message: 'Invalid input',
          data: { field: 'email', reason: 'format' },
        },
      });
    });
  });

  describe('introspection', () => {
    it('should return registration count', () => {
      registry.register('system.ping', vi.fn());
      registry.register('system.getInfo', vi.fn());

      expect(registry.size).toBe(2);
    });

    it('should provide namespaces', () => {
      registry.register('system.ping', vi.fn());
      registry.register('system.getInfo', vi.fn());
      registry.register('session.create', vi.fn());
      registry.register('agent.prompt', vi.fn());

      const namespaces = registry.namespaces;
      expect(namespaces).toContain('system');
      expect(namespaces).toContain('session');
      expect(namespaces).toContain('agent');
      expect(namespaces).toHaveLength(3);
    });
  });
});
