/**
 * @fileoverview Tests for Worktree RPC Handlers
 *
 * Tests worktree.getStatus, worktree.commit, worktree.merge, worktree.list handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createWorktreeHandlers,
  handleWorktreeGetStatus,
  handleWorktreeCommit,
  handleWorktreeMerge,
  handleWorktreeList,
} from './worktree.handler.js';
import type { RpcRequest } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry } from '../registry.js';

describe('Worktree Handlers', () => {
  let mockContext: RpcContext;
  let mockContextWithoutWorktreeManager: RpcContext;
  let mockGetWorktreeStatus: ReturnType<typeof vi.fn>;
  let mockCommitWorktree: ReturnType<typeof vi.fn>;
  let mockMergeWorktree: ReturnType<typeof vi.fn>;
  let mockListWorktrees: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockGetWorktreeStatus = vi.fn().mockResolvedValue({
      path: '/projects/myapp/.worktrees/sess-123',
      branch: 'session/sess-123',
      status: 'clean',
      changedFiles: [],
    });

    mockCommitWorktree = vi.fn().mockResolvedValue({
      commitHash: 'abc123',
      message: 'Test commit',
      filesChanged: 3,
    });

    mockMergeWorktree = vi.fn().mockResolvedValue({
      merged: true,
      conflicts: [],
      commitHash: 'def456',
    });

    mockListWorktrees = vi.fn().mockResolvedValue([
      { sessionId: 'sess-1', path: '/worktrees/sess-1', branch: 'session/sess-1' },
      { sessionId: 'sess-2', path: '/worktrees/sess-2', branch: 'session/sess-2' },
    ]);

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
      worktreeManager: {
        getWorktreeStatus: mockGetWorktreeStatus,
        commitWorktree: mockCommitWorktree,
        mergeWorktree: mockMergeWorktree,
        listWorktrees: mockListWorktrees,
      } as any,
    };

    mockContextWithoutWorktreeManager = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handleWorktreeGetStatus', () => {
    it('should get worktree status for a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.getStatus',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleWorktreeGetStatus(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetWorktreeStatus).toHaveBeenCalledWith('sess-123');
      const result = response.result as { hasWorktree: boolean; worktree: any };
      expect(result.hasWorktree).toBe(true);
      expect(result.worktree.branch).toBe('session/sess-123');
    });

    it('should return hasWorktree false when no worktree', async () => {
      mockGetWorktreeStatus.mockResolvedValueOnce(null);

      const request: RpcRequest = {
        id: '1',
        method: 'worktree.getStatus',
        params: { sessionId: 'sess-456' },
      };

      const response = await handleWorktreeGetStatus(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { hasWorktree: boolean };
      expect(result.hasWorktree).toBe(false);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.getStatus',
        params: {},
      };

      const response = await handleWorktreeGetStatus(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_SUPPORTED without worktreeManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.getStatus',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleWorktreeGetStatus(request, mockContextWithoutWorktreeManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleWorktreeCommit', () => {
    it('should commit worktree changes', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.commit',
        params: { sessionId: 'sess-123', message: 'Test commit' },
      };

      const response = await handleWorktreeCommit(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockCommitWorktree).toHaveBeenCalledWith('sess-123', 'Test commit');
      const result = response.result as { commitHash: string };
      expect(result.commitHash).toBe('abc123');
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.commit',
        params: { message: 'Test' },
      };

      const response = await handleWorktreeCommit(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing message', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.commit',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleWorktreeCommit(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('message');
    });

    it('should return NOT_SUPPORTED without worktreeManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.commit',
        params: { sessionId: 'sess-123', message: 'Test' },
      };

      const response = await handleWorktreeCommit(request, mockContextWithoutWorktreeManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleWorktreeMerge', () => {
    it('should merge worktree to target branch', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.merge',
        params: { sessionId: 'sess-123', targetBranch: 'main' },
      };

      const response = await handleWorktreeMerge(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockMergeWorktree).toHaveBeenCalledWith('sess-123', 'main', undefined);
      const result = response.result as { merged: boolean };
      expect(result.merged).toBe(true);
    });

    it('should pass merge strategy', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.merge',
        params: { sessionId: 'sess-123', targetBranch: 'main', strategy: 'squash' },
      };

      const response = await handleWorktreeMerge(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockMergeWorktree).toHaveBeenCalledWith('sess-123', 'main', 'squash');
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.merge',
        params: { targetBranch: 'main' },
      };

      const response = await handleWorktreeMerge(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing targetBranch', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.merge',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleWorktreeMerge(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('targetBranch');
    });

    it('should return NOT_SUPPORTED without worktreeManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.merge',
        params: { sessionId: 'sess-123', targetBranch: 'main' },
      };

      const response = await handleWorktreeMerge(request, mockContextWithoutWorktreeManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('handleWorktreeList', () => {
    it('should list all worktrees', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.list',
      };

      const response = await handleWorktreeList(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListWorktrees).toHaveBeenCalled();
      const result = response.result as { worktrees: any[] };
      expect(result.worktrees).toHaveLength(2);
    });

    it('should return NOT_SUPPORTED without worktreeManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.list',
      };

      const response = await handleWorktreeList(request, mockContextWithoutWorktreeManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });
  });

  describe('createWorktreeHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createWorktreeHandlers();

      expect(handlers).toHaveLength(4);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('worktree.getStatus');
      expect(methods).toContain('worktree.commit');
      expect(methods).toContain('worktree.merge');
      expect(methods).toContain('worktree.list');
    });

    it('should have worktreeManager as required for all handlers', () => {
      const handlers = createWorktreeHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('worktreeManager');
      }
    });

    it('should have correct required params', () => {
      const handlers = createWorktreeHandlers();

      const commitHandler = handlers.find(h => h.method === 'worktree.commit');
      expect(commitHandler?.options?.requiredParams).toContain('sessionId');
      expect(commitHandler?.options?.requiredParams).toContain('message');

      const mergeHandler = handlers.find(h => h.method === 'worktree.merge');
      expect(mergeHandler?.options?.requiredParams).toContain('sessionId');
      expect(mergeHandler?.options?.requiredParams).toContain('targetBranch');
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch worktree handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createWorktreeHandlers();
      registry.registerAll(handlers);

      expect(registry.has('worktree.getStatus')).toBe(true);
      expect(registry.has('worktree.commit')).toBe(true);
      expect(registry.has('worktree.merge')).toBe(true);
      expect(registry.has('worktree.list')).toBe(true);

      // Test worktree.list through registry
      const request: RpcRequest = {
        id: '1',
        method: 'worktree.list',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('worktrees');
    });
  });
});
