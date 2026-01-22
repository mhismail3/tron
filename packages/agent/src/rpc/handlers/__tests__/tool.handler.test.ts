/**
 * Tests for tool.handler.ts
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleToolResult,
  createToolHandlers,
} from '../tool.handler.js';
import type { RpcRequest, RpcResponse } from '../../types.js';
import type { RpcContext } from '../handler.js';

describe('tool.handler', () => {
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      toolCallTracker: {
        hasPending: vi.fn(),
        resolve: vi.fn(),
      },
    } as unknown as RpcContext;
  });

  describe('handleToolResult', () => {
    it('should return error when toolCallTracker is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      const contextWithoutTracker = {} as RpcContext;
      const response = await handleToolResult(request, contextWithoutTracker);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Tool call tracker not available');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { toolCallId: 'tool-456', result: 'success' },
      };

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when toolCallId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', result: 'success' },
      };

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('toolCallId is required');
    });

    it('should return error when result is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456' },
      };

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('result is required');
    });

    it('should return error when tool call is not pending', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(false);

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_FOUND');
      expect(response.error?.message).toBe('No pending tool call found with ID: tool-456');
    });

    it('should return error when resolve fails', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(false);

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('TOOL_RESULT_FAILED');
      expect(response.error?.message).toBe('Failed to resolve tool call');
    });

    it('should resolve tool call successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: { data: 'test output' } },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
        toolCallId: 'tool-456',
      });
      expect(mockContext.toolCallTracker!.hasPending).toHaveBeenCalledWith('tool-456');
      expect(mockContext.toolCallTracker!.resolve).toHaveBeenCalledWith('tool-456', { data: 'test output' });
    });

    it('should handle string result', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'simple string result' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockContext.toolCallTracker!.resolve).toHaveBeenCalledWith('tool-456', 'simple string result');
    });

    it('should handle null result', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: null },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await handleToolResult(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockContext.toolCallTracker!.resolve).toHaveBeenCalledWith('tool-456', null);
    });
  });

  describe('createToolHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createToolHandlers();

      expect(registrations).toHaveLength(1);
      expect(registrations[0].method).toBe('tool.result');
      expect(registrations[0].options?.requiredParams).toContain('sessionId');
      expect(registrations[0].options?.requiredParams).toContain('toolCallId');
      expect(registrations[0].options?.requiredParams).toContain('result');
      expect(registrations[0].options?.requiredManagers).toContain('toolCallTracker');
    });

    it('should create handler that returns result on success', async () => {
      const registrations = createToolHandlers();
      const handler = registrations[0].handler;

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'done' },
      };

      const result = await handler(request, mockContext);

      expect(result).toEqual({
        success: true,
        toolCallId: 'tool-456',
      });
    });

    it('should create handler that throws on error', async () => {
      const registrations = createToolHandlers();
      const handler = registrations[0].handler;

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: {},
      };

      await expect(handler(request, mockContext)).rejects.toThrow('sessionId is required');
    });

    it('should create handler that throws on not found', async () => {
      const registrations = createToolHandlers();
      const handler = registrations[0].handler;

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(false);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'done' },
      };

      await expect(handler(request, mockContext)).rejects.toThrow('No pending tool call found with ID: tool-456');
    });
  });
});
