/**
 * Tests for browser.handler.ts
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleBrowserStartStream,
  handleBrowserStopStream,
  handleBrowserGetStatus,
  createBrowserHandlers,
} from '../browser.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';

describe('browser.handler', () => {
  let mockContext: RpcContext;
  let mockStartStream: ReturnType<typeof vi.fn>;
  let mockStopStream: ReturnType<typeof vi.fn>;
  let mockGetStatus: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockStartStream = vi.fn().mockResolvedValue({ success: true });
    mockStopStream = vi.fn().mockResolvedValue({ success: true });
    mockGetStatus = vi.fn().mockResolvedValue({ hasBrowser: true, isStreaming: false });

    mockContext = {
      browserManager: {
        startStream: mockStartStream,
        stopStream: mockStopStream,
        getStatus: mockGetStatus,
      },
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    } as unknown as RpcContext;
  });

  describe('handleBrowserStartStream', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
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
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { success: true };
      mockStartStream.mockResolvedValue(mockResult);

      const response = await handleBrowserStartStream(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockStartStream).toHaveBeenCalledWith({ sessionId: 'session-123' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      mockStartStream.mockRejectedValue(new Error('Browser not connected'));

      const response = await handleBrowserStartStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
      expect(response.error?.message).toBe('Browser not connected');
    });
  });

  describe('handleBrowserStopStream', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
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
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { success: true };
      mockStopStream.mockResolvedValue(mockResult);

      const response = await handleBrowserStopStream(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      mockStopStream.mockRejectedValue(new Error('Stream not found'));

      const response = await handleBrowserStopStream(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
    });
  });

  describe('handleBrowserGetStatus', () => {
    it('should return error when browserManager is not available', async () => {
      const request: RpcRequest = {
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
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { hasBrowser: true, isStreaming: true };
      mockGetStatus.mockResolvedValue(mockResult);

      const response = await handleBrowserGetStatus(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      mockGetStatus.mockRejectedValue(new Error('Session not found'));

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

      const mockResult = { success: true };
      mockStartStream.mockResolvedValue(mockResult);

      const request: RpcRequest = {
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
        id: '1',
        method: 'browser.startStream',
        params: {},
      };

      await expect(handler(request, mockContext)).rejects.toThrow('sessionId is required');
    });
  });
});
