/**
 * @fileoverview Tests for Context RPC Handlers
 *
 * Tests context.getSnapshot, context.getDetailedSnapshot, context.shouldCompact,
 * context.previewCompaction, context.confirmCompaction, context.canAcceptTurn, context.clear handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createContextHandlers } from '../context.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Context Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutContextManager: RpcContext;
  let mockGetContextSnapshot: ReturnType<typeof vi.fn>;
  let mockGetDetailedContextSnapshot: ReturnType<typeof vi.fn>;
  let mockShouldCompact: ReturnType<typeof vi.fn>;
  let mockPreviewCompaction: ReturnType<typeof vi.fn>;
  let mockConfirmCompaction: ReturnType<typeof vi.fn>;
  let mockCanAcceptTurn: ReturnType<typeof vi.fn>;
  let mockClearContext: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createContextHandlers());

    mockGetContextSnapshot = vi.fn().mockReturnValue({
      sessionId: 'sess-123',
      totalTokens: 50000,
      maxTokens: 200000,
      usagePercent: 25,
    });

    mockGetDetailedContextSnapshot = vi.fn().mockReturnValue({
      sessionId: 'sess-123',
      totalTokens: 50000,
      maxTokens: 200000,
      messageBreakdown: [
        { role: 'user', tokens: 20000 },
        { role: 'assistant', tokens: 30000 },
      ],
    });

    mockShouldCompact = vi.fn().mockReturnValue(false);

    mockPreviewCompaction = vi.fn().mockResolvedValue({
      summary: 'Conversation about building a React app',
      messagesRemoved: 10,
      tokensSaved: 15000,
    });

    mockConfirmCompaction = vi.fn().mockResolvedValue({
      compacted: true,
      newTokenCount: 35000,
      messagesRemoved: 10,
    });

    mockCanAcceptTurn = vi.fn().mockReturnValue({
      canAccept: true,
      availableTokens: 100000,
      reason: null,
    });

    mockClearContext = vi.fn().mockResolvedValue({
      cleared: true,
      previousTokenCount: 50000,
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      contextManager: {
        getContextSnapshot: mockGetContextSnapshot,
        getDetailedContextSnapshot: mockGetDetailedContextSnapshot,
        shouldCompact: mockShouldCompact,
        previewCompaction: mockPreviewCompaction,
        confirmCompaction: mockConfirmCompaction,
        canAcceptTurn: mockCanAcceptTurn,
        clearContext: mockClearContext,
      } as any,
    };

    mockContextWithoutContextManager = {
      sessionManager: {} as any,
      agentManager: {} as any,
    };
  });

  describe('context.getSnapshot', () => {
    it('should get context snapshot', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.getSnapshot',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetContextSnapshot).toHaveBeenCalledWith('sess-123');
      const result = response.result as { totalTokens: number };
      expect(result.totalTokens).toBe(50000);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.getSnapshot',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should return SESSION_NOT_ACTIVE for inactive session', async () => {
      mockGetContextSnapshot.mockImplementationOnce(() => {
        throw new Error('Session not active');
      });

      const request: RpcRequest = {
        id: '1',
        method: 'context.getSnapshot',
        params: { sessionId: 'sess-inactive' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_ACTIVE');
    });

    it('should return NOT_AVAILABLE without contextManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.getSnapshot',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutContextManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('context.getDetailedSnapshot', () => {
    it('should get detailed context snapshot', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.getDetailedSnapshot',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetDetailedContextSnapshot).toHaveBeenCalledWith('sess-123');
      const result = response.result as { messageBreakdown: any[] };
      expect(result.messageBreakdown).toHaveLength(2);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.getDetailedSnapshot',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('context.shouldCompact', () => {
    it('should check if should compact', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.shouldCompact',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockShouldCompact).toHaveBeenCalledWith('sess-123');
      const result = response.result as { shouldCompact: boolean };
      expect(result.shouldCompact).toBe(false);
    });

    it('should return true when compaction needed', async () => {
      mockShouldCompact.mockReturnValueOnce(true);

      const request: RpcRequest = {
        id: '1',
        method: 'context.shouldCompact',
        params: { sessionId: 'sess-full' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { shouldCompact: boolean };
      expect(result.shouldCompact).toBe(true);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.shouldCompact',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('context.previewCompaction', () => {
    it('should preview compaction', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.previewCompaction',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockPreviewCompaction).toHaveBeenCalledWith('sess-123');
      const result = response.result as { summary: string };
      expect(result.summary).toContain('React');
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.previewCompaction',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('context.confirmCompaction', () => {
    it('should confirm compaction', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.confirmCompaction',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockConfirmCompaction).toHaveBeenCalledWith('sess-123', { editedSummary: undefined });
      const result = response.result as { compacted: boolean };
      expect(result.compacted).toBe(true);
    });

    it('should pass edited summary', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.confirmCompaction',
        params: { sessionId: 'sess-123', editedSummary: 'Custom summary' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockConfirmCompaction).toHaveBeenCalledWith('sess-123', { editedSummary: 'Custom summary' });
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.confirmCompaction',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('context.canAcceptTurn', () => {
    it('should check if can accept turn', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.canAcceptTurn',
        params: { sessionId: 'sess-123', estimatedResponseTokens: 5000 },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockCanAcceptTurn).toHaveBeenCalledWith('sess-123', { estimatedResponseTokens: 5000 });
      const result = response.result as { canAccept: boolean };
      expect(result.canAccept).toBe(true);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.canAcceptTurn',
        params: { estimatedResponseTokens: 5000 },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing estimatedResponseTokens', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.canAcceptTurn',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('estimatedResponseTokens');
    });
  });

  describe('context.clear', () => {
    it('should clear context', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.clear',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockClearContext).toHaveBeenCalledWith('sess-123');
      const result = response.result as { cleared: boolean };
      expect(result.cleared).toBe(true);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'context.clear',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('createContextHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createContextHandlers();

      expect(handlers).toHaveLength(8);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('context.getSnapshot');
      expect(methods).toContain('context.getDetailedSnapshot');
      expect(methods).toContain('context.shouldCompact');
      expect(methods).toContain('context.previewCompaction');
      expect(methods).toContain('context.confirmCompaction');
      expect(methods).toContain('context.canAcceptTurn');
      expect(methods).toContain('context.clear');
      expect(methods).toContain('context.compact'); // Legacy alias
    });

    it('should have contextManager as required for all handlers', () => {
      const handlers = createContextHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('contextManager');
      }
    });

    it('should have correct required params for canAcceptTurn', () => {
      const handlers = createContextHandlers();
      const canAcceptHandler = handlers.find(h => h.method === 'context.canAcceptTurn');

      expect(canAcceptHandler?.options?.requiredParams).toContain('sessionId');
      expect(canAcceptHandler?.options?.requiredParams).toContain('estimatedResponseTokens');
    });
  });
});
