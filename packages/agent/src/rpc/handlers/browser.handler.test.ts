/**
 * Tests for browser.handler.ts
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleBrowserStartStream,
  handleBrowserStopStream,
  handleBrowserGetStatus,
  createBrowserHandlers,
} from './browser.handler.js';
import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';

describe('browser.handler', () => {
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      browserManager: {
        startStream: vi.fn(),
        stopStream: vi.fn(),
        getStatus: vi.fn(),
      },
    } as unknown as RpcContext;
  });

  describe('handleBrowserStartStream', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const contextWithoutBrowser = {} as RpcContext;
      const response = await handleBrowserStartStream(request, contextWithoutBrowser);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Browser manager not available');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: {},
      };

      const response = await handleBrowserStartStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should start stream successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { streamId: 'stream-456', status: 'started' };
      vi.mocked(mockContext.browserManager!.startStream).mockResolvedValue(mockResult);

      const response = await handleBrowserStartStream(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockContext.browserManager!.startStream).toHaveBeenCalledWith({ sessionId: 'session-123' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      vi.mocked(mockContext.browserManager!.startStream).mockRejectedValue(new Error('Browser not connected'));

      const response = await handleBrowserStartStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
      expect(response.error?.message).toBe('Browser not connected');
    });
  });

  describe('handleBrowserStopStream', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      const contextWithoutBrowser = {} as RpcContext;
      const response = await handleBrowserStopStream(request, contextWithoutBrowser);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.stopStream',
        params: {},
      };

      const response = await handleBrowserStopStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should stop stream successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { status: 'stopped' };
      vi.mocked(mockContext.browserManager!.stopStream).mockResolvedValue(mockResult);

      const response = await handleBrowserStopStream(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      vi.mocked(mockContext.browserManager!.stopStream).mockRejectedValue(new Error('Stream not found'));

      const response = await handleBrowserStopStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
    });
  });

  describe('handleBrowserGetStatus', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      const contextWithoutBrowser = {} as RpcContext;
      const response = await handleBrowserGetStatus(request, contextWithoutBrowser);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.getStatus',
        params: {},
      };

      const response = await handleBrowserGetStatus(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should get status successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { isStreaming: true, frameCount: 150 };
      vi.mocked(mockContext.browserManager!.getStatus).mockResolvedValue(mockResult);

      const response = await handleBrowserGetStatus(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      vi.mocked(mockContext.browserManager!.getStatus).mockRejectedValue(new Error('Session not found'));

      const response = await handleBrowserGetStatus(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
    });
  });

  describe('createBrowserHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createBrowserHandlers();

      expect(registrations).toHaveLength(3);

      const methods = registrations.map(r => r.method);
      expect(methods).toContain('browser.startStream');
      expect(methods).toContain('browser.stopStream');
      expect(methods).toContain('browser.getStatus');

      for (const reg of registrations) {
        expect(reg.options?.requiredParams).toContain('sessionId');
        expect(reg.options?.requiredManagers).toContain('browserManager');
      }
    });

    it('should create handlers that return results on success', async () => {
      const registrations = createBrowserHandlers();
      const startHandler = registrations.find(r => r.method === 'browser.startStream')!.handler;

      const mockResult = { streamId: 'stream-789' };
      vi.mocked(mockContext.browserManager!.startStream).mockResolvedValue(mockResult);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const result = await startHandler(request, mockContext);

      expect(result).toEqual(mockResult);
    });

    it('should create handlers that throw on error', async () => {
      const registrations = createBrowserHandlers();
      const handler = registrations[0].handler;

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'browser.startStream',
        params: {},
      };

      await expect(handler(request, mockContext)).rejects.toThrow('sessionId is required');
    });
  });
});
