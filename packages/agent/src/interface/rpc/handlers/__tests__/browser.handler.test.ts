/**
 * @fileoverview Tests for Browser RPC Handlers
 *
 * Tests browser.startStream, browser.stopStream, browser.getStatus handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createBrowserHandlers } from '../browser.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Browser Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutBrowserManager: RpcContext;
  let mockStartStream: ReturnType<typeof vi.fn>;
  let mockStopStream: ReturnType<typeof vi.fn>;
  let mockGetStatus: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createBrowserHandlers());

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

    mockContextWithoutBrowserManager = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('browser.startStream', () => {
    it('should return NOT_AVAILABLE when browserManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutBrowserManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.startStream',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should start stream successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.startStream',
        params: { sessionId: 'session-123' },
      };

      const mockResult = { success: true };
      mockStartStream.mockResolvedValue(mockResult);

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
      expect(response.error?.message).toBe('Browser not connected');
    });
  });

  describe('browser.stopStream', () => {
    it('should return NOT_AVAILABLE when browserManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.stopStream',
        params: { sessionId: 'session-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutBrowserManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.stopStream',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('BROWSER_ERROR');
    });
  });

  describe('browser.getStatus', () => {
    it('should return NOT_AVAILABLE when browserManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.getStatus',
        params: { sessionId: 'session-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutBrowserManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'browser.getStatus',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

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
  });
});
