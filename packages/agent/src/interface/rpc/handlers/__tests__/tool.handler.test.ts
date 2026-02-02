/**
 * @fileoverview Tests for Tool RPC Handlers
 *
 * Tests tool.result handler using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createToolHandlers } from '../tool.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Tool Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutToolCallTracker: RpcContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createToolHandlers());

    mockContext = {
      toolCallTracker: {
        hasPending: vi.fn(),
        resolve: vi.fn(),
      },
    } as unknown as RpcContext;

    mockContextWithoutToolCallTracker = {} as RpcContext;
  });

  describe('tool.result', () => {
    it('should return NOT_AVAILABLE when toolCallTracker is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      const response = await registry.dispatch(request, mockContextWithoutToolCallTracker);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { toolCallId: 'tool-456', result: 'success' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error when toolCallId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', result: 'success' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('toolCallId');
    });

    it('should return error when result is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('result');
    });

    it('should return error when tool call is not pending', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(false);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_FOUND');
      expect(response.error?.message).toBe('No pending tool call found with ID: tool-456');
    });

    it('should return error when resolve fails', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'success' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(false);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('TOOL_RESULT_FAILED');
      expect(response.error?.message).toBe('Failed to resolve tool call');
    });

    it('should resolve tool call successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: { data: 'test output' } },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await registry.dispatch(request, mockContext);

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
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: 'simple string result' },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockContext.toolCallTracker!.resolve).toHaveBeenCalledWith('tool-456', 'simple string result');
    });

    it('should handle null result', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'tool.result',
        params: { sessionId: 'session-123', toolCallId: 'tool-456', result: null },
      };

      vi.mocked(mockContext.toolCallTracker!.hasPending).mockReturnValue(true);
      vi.mocked(mockContext.toolCallTracker!.resolve).mockReturnValue(true);

      const response = await registry.dispatch(request, mockContext);

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
  });
});
