/**
 * @fileoverview Tests for Base Handler Utilities
 *
 * Tests parameter extraction, manager access, and handler factory utilities.
 */

import { describe, it, expect, vi } from 'vitest';
import {
  extractParams,
  extractRequiredParams,
  requireManager,
  createHandler,
  withErrorHandling,
  notFoundError,
} from '../../../src/rpc/handlers/base.js';
import type { RpcRequest } from '../../../src/rpc/types.js';
import type { RpcContext } from '../../../src/rpc/handler.js';

describe('Base Handler Utilities', () => {
  describe('extractParams', () => {
    it('should extract params from request', () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: { foo: 'bar', count: 42 },
      };

      const params = extractParams<{ foo: string; count: number }>(request);

      expect(params).toEqual({ foo: 'bar', count: 42 });
    });

    it('should return undefined when no params', () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
      };

      const params = extractParams(request);

      expect(params).toBeUndefined();
    });
  });

  describe('extractRequiredParams', () => {
    it('should return success with params when all required fields present', () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: { workingDirectory: '/test', model: 'claude-3' },
      };

      const result = extractRequiredParams<{ workingDirectory: string; model: string }>(
        request,
        ['workingDirectory']
      );

      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.params.workingDirectory).toBe('/test');
      }
    });

    it('should return error response when required field is missing', () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: { model: 'claude-3' }, // Missing workingDirectory
      };

      const result = extractRequiredParams<{ workingDirectory: string }>(
        request,
        ['workingDirectory']
      );

      expect(result.success).toBe(false);
      if (!result.success) {
        expect(result.response.error?.code).toBe('INVALID_PARAMS');
        expect(result.response.error?.message).toContain('workingDirectory');
      }
    });

    it('should return error response when params is undefined', () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
      };

      const result = extractRequiredParams<{ workingDirectory: string }>(
        request,
        ['workingDirectory']
      );

      expect(result.success).toBe(false);
    });
  });

  describe('requireManager', () => {
    it('should return manager when available', () => {
      const mockSessionManager = { createSession: vi.fn() };
      const context: RpcContext = {
        sessionManager: mockSessionManager as any,
        agentManager: {} as any,
        memoryStore: {} as any,
      };

      const result = requireManager(context, 'sessionManager', 'req-1');

      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.manager).toBe(mockSessionManager);
      }
    });

    it('should return error when manager not available', () => {
      const context: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
        memoryStore: {} as any,
        // transcriptionManager is undefined
      };

      const result = requireManager(context, 'transcriptionManager', 'req-1');

      expect(result.success).toBe(false);
      if (!result.success) {
        expect(result.response.error?.code).toBe('NOT_AVAILABLE');
        expect(result.response.error?.message).toContain('transcriptionManager');
      }
    });
  });

  describe('notFoundError', () => {
    it('should create not found error with identifier', () => {
      const response = notFoundError('req-1', 'Session', 'sess-123');

      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.error?.message).toContain('Session');
      expect(response.error?.message).toContain('sess-123');
    });

    it('should create not found error without identifier', () => {
      const response = notFoundError('req-1', 'Session');

      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.error?.message).toBe('Session not found');
    });
  });

  describe('withErrorHandling', () => {
    it('should wrap successful handler', async () => {
      const handler = vi.fn().mockResolvedValue({ result: 'ok' });
      const wrapped = withErrorHandling(handler);
      const context = {} as RpcContext;
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await wrapped({}, context, request);

      expect(response.result).toEqual({ result: 'ok' });
      expect(response.error).toBeUndefined();
    });

    it('should catch and format errors', async () => {
      const handler = vi.fn().mockRejectedValue(new Error('Something broke'));
      const wrapped = withErrorHandling(handler);
      const context = {} as RpcContext;
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await wrapped({}, context, request);

      expect(response.error?.code).toBe('INTERNAL_ERROR');
      expect(response.error?.message).toContain('Something broke');
    });

    it('should handle not found errors specially', async () => {
      const handler = vi.fn().mockRejectedValue(new Error('Session not found: xyz'));
      const wrapped = withErrorHandling(handler);
      const context = {} as RpcContext;
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await wrapped({}, context, request);

      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
    });
  });

  describe('createHandler', () => {
    it('should create handler with validation', async () => {
      const impl = vi.fn().mockResolvedValue({ sessionId: 'new-sess' });
      const handler = createHandler<{ workingDirectory: string }, { sessionId: string }>(
        { requiredParams: ['workingDirectory'] },
        impl
      );

      const context: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
        memoryStore: {} as any,
      };

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: { workingDirectory: '/test' },
      };

      const response = await handler(request, context);

      expect(response.result).toEqual({ sessionId: 'new-sess' });
      expect(impl).toHaveBeenCalledWith(
        { workingDirectory: '/test' },
        context,
        request
      );
    });

    it('should reject when required param missing', async () => {
      const impl = vi.fn();
      const handler = createHandler<{ workingDirectory: string }, unknown>(
        { requiredParams: ['workingDirectory'] },
        impl
      );

      const context: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
        memoryStore: {} as any,
      };

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'session.create',
        params: {},
      };

      const response = await handler(request, context);

      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(impl).not.toHaveBeenCalled();
    });

    it('should reject when required manager missing', async () => {
      const impl = vi.fn();
      const handler = createHandler<object, unknown>(
        { requiredManagers: ['transcriptionManager'] },
        impl
      );

      const context: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
        memoryStore: {} as any,
      };

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'transcribe.audio',
        params: {},
      };

      const response = await handler(request, context);

      expect(response.error?.code).toBe('NOT_AVAILABLE');
      expect(impl).not.toHaveBeenCalled();
    });
  });
});
