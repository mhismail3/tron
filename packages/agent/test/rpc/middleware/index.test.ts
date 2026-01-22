/**
 * @fileoverview Tests for RPC Middleware Utilities
 *
 * Tests middleware chain building and common middleware patterns.
 */

import { describe, it, expect, vi } from 'vitest';
import {
  buildMiddlewareChain,
  createTimingMiddleware,
  createLoggingMiddleware,
  createErrorBoundaryMiddleware,
  type Middleware,
} from '../../../src/rpc/middleware/index.js';
import type { RpcRequest, RpcResponse } from '../../../src/rpc/types.js';

describe('Middleware Utilities', () => {
  describe('buildMiddlewareChain', () => {
    it('should execute handler when no middleware', async () => {
      const handler = vi.fn().mockResolvedValue({
        id: '1',
        success: true,
        result: { ok: true },
      } as RpcResponse);

      const chain = buildMiddlewareChain([], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(handler).toHaveBeenCalledWith(request);
      expect(response.result).toEqual({ ok: true });
    });

    it('should execute middleware in order', async () => {
      const order: string[] = [];

      const mw1: Middleware = async (req, next) => {
        order.push('mw1-before');
        const res = await next(req);
        order.push('mw1-after');
        return res;
      };

      const mw2: Middleware = async (req, next) => {
        order.push('mw2-before');
        const res = await next(req);
        order.push('mw2-after');
        return res;
      };

      const handler = vi.fn().mockImplementation(async () => {
        order.push('handler');
        return { id: '1', success: true, result: {} } as RpcResponse;
      });

      const chain = buildMiddlewareChain([mw1, mw2], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      await chain(request);

      expect(order).toEqual([
        'mw1-before',
        'mw2-before',
        'handler',
        'mw2-after',
        'mw1-after',
      ]);
    });

    it('should allow middleware to short-circuit', async () => {
      const shortCircuit: Middleware = async () => {
        return { id: '1', success: false, error: { code: 'AUTH_FAILED', message: 'Unauthorized' } };
      };

      const handler = vi.fn();

      const chain = buildMiddlewareChain([shortCircuit], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(response.error?.code).toBe('AUTH_FAILED');
      expect(handler).not.toHaveBeenCalled();
    });

    it('should use onError handler when middleware throws', async () => {
      const throwingMiddleware: Middleware = async () => {
        throw new Error('Middleware exploded');
      };

      const handler = vi.fn();
      const onError = vi.fn().mockReturnValue({
        jsonrpc: '2.0',
        id: '1',
        error: { code: 'INTERNAL_ERROR', message: 'Handled error' },
      } as RpcResponse);

      const chain = buildMiddlewareChain([throwingMiddleware], handler, { onError });
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(onError).toHaveBeenCalled();
      expect(response.error?.code).toBe('INTERNAL_ERROR');
    });

    it('should allow middleware to modify request', async () => {
      const modifyingMiddleware: Middleware = async (req, next) => {
        return next({ ...req, params: { ...req.params as object, injected: true } });
      };

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        result: {},
      } as RpcResponse);

      const chain = buildMiddlewareChain([modifyingMiddleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test', params: { original: true } };

      await chain(request);

      expect(handler).toHaveBeenCalledWith(
        expect.objectContaining({
          params: { original: true, injected: true },
        })
      );
    });

    it('should allow middleware to modify response', async () => {
      const modifyingMiddleware: Middleware = async (req, next) => {
        const response = await next(req);
        return {
          ...response,
          result: { ...(response.result as object), modified: true },
        };
      };

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        result: { original: true },
      } as RpcResponse);

      const chain = buildMiddlewareChain([modifyingMiddleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(response.result).toEqual({ original: true, modified: true });
    });
  });

  describe('createTimingMiddleware', () => {
    it('should call logger with method and duration', async () => {
      const logger = vi.fn();
      const middleware = createTimingMiddleware(logger);

      const handler = vi.fn().mockImplementation(async () => {
        // Simulate some work
        await new Promise((resolve) => setTimeout(resolve, 10));
        return { jsonrpc: '2.0', id: '1', result: {} } as RpcResponse;
      });

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test.method' };

      await chain(request);

      expect(logger).toHaveBeenCalledWith('test.method', expect.any(Number));
      const [, duration] = logger.mock.calls[0] as [string, number];
      expect(duration).toBeGreaterThanOrEqual(10);
    });

    it('should work without logger', async () => {
      const middleware = createTimingMiddleware();

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        result: { ok: true },
      } as RpcResponse);

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(response.result).toEqual({ ok: true });
    });
  });

  describe('createLoggingMiddleware', () => {
    it('should log request and successful response', async () => {
      const log = vi.fn();
      const middleware = createLoggingMiddleware(log);

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        result: { ok: true },
      } as RpcResponse);

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test.method' };

      await chain(request);

      expect(log).toHaveBeenCalledWith('debug', 'RPC request: test.method', expect.any(Object));
      expect(log).toHaveBeenCalledWith('debug', 'RPC success: test.method', expect.any(Object));
    });

    it('should log warnings for error responses', async () => {
      const log = vi.fn();
      const middleware = createLoggingMiddleware(log);

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        error: { code: 'INVALID_PARAMS', message: 'Bad request' },
      } as RpcResponse);

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test.method' };

      await chain(request);

      expect(log).toHaveBeenCalledWith('warn', 'RPC error: test.method', expect.any(Object));
    });

    it('should log errors for exceptions', async () => {
      const log = vi.fn();
      const middleware = createLoggingMiddleware(log);

      const handler = vi.fn().mockRejectedValue(new Error('Boom'));

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test.method' };

      await expect(chain(request)).rejects.toThrow('Boom');

      expect(log).toHaveBeenCalledWith('error', 'RPC exception: test.method', expect.any(Object));
    });
  });

  describe('createErrorBoundaryMiddleware', () => {
    it('should pass through successful responses', async () => {
      const formatError = vi.fn();
      const middleware = createErrorBoundaryMiddleware(formatError);

      const handler = vi.fn().mockResolvedValue({
        jsonrpc: '2.0',
        id: '1',
        result: { ok: true },
      } as RpcResponse);

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(response.result).toEqual({ ok: true });
      expect(formatError).not.toHaveBeenCalled();
    });

    it('should catch and format errors', async () => {
      const formatError = vi.fn().mockReturnValue({
        jsonrpc: '2.0',
        id: '1',
        error: { code: 'INTERNAL_ERROR', message: 'Formatted error' },
      } as RpcResponse);

      const middleware = createErrorBoundaryMiddleware(formatError);

      const handler = vi.fn().mockRejectedValue(new Error('Original error'));

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      const response = await chain(request);

      expect(formatError).toHaveBeenCalledWith(expect.any(Error), '1');
      expect(response.error?.message).toBe('Formatted error');
    });

    it('should convert non-Error to Error', async () => {
      const formatError = vi.fn().mockReturnValue({
        jsonrpc: '2.0',
        id: '1',
        error: { code: 'INTERNAL_ERROR', message: 'Error' },
      } as RpcResponse);

      const middleware = createErrorBoundaryMiddleware(formatError);

      const handler = vi.fn().mockRejectedValue('string error');

      const chain = buildMiddlewareChain([middleware], handler);
      const request: RpcRequest = { jsonrpc: '2.0', id: '1', method: 'test' };

      await chain(request);

      const [error] = formatError.mock.calls[0] as [Error, string];
      expect(error).toBeInstanceOf(Error);
      expect(error.message).toBe('string error');
    });
  });
});
