/**
 * @fileoverview Worktree Store Tests (TDD)
 *
 * Tests for the worktree state management store.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { useWorktreeStore, worktreeReducer, initialWorktreeState } from '../../src/store/worktree-store.js';
import type { WorktreeState, WorktreeAction } from '../../src/store/worktree-store.js';

// =============================================================================
// Reducer Tests
// =============================================================================

describe('worktreeReducer', () => {
  it('should return initial state', () => {
    const state = worktreeReducer(undefined, { type: 'WORKTREE_RESET' });
    expect(state).toEqual(initialWorktreeState);
  });

  describe('WORKTREE_SET_STATUS', () => {
    it('should set worktree status for a session', () => {
      const action: WorktreeAction = {
        type: 'WORKTREE_SET_STATUS',
        payload: {
          sessionId: 'session_123',
          status: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'session/session_123',
              baseCommit: 'abc123',
              path: '/path/to/.worktrees/session_123',
              hasUncommittedChanges: false,
              commitCount: 2,
            },
          },
        },
      };

      const state = worktreeReducer(initialWorktreeState, action);
      expect(state.sessionWorktrees['session_123']).toBeDefined();
      expect(state.sessionWorktrees['session_123']?.hasWorktree).toBe(true);
      expect(state.sessionWorktrees['session_123']?.worktree?.branch).toBe('session/session_123');
    });

    it('should update existing worktree status', () => {
      const initialStateWithWorktree: WorktreeState = {
        ...initialWorktreeState,
        sessionWorktrees: {
          session_123: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'session/session_123',
              baseCommit: 'abc123',
              path: '/path/to/.worktrees/session_123',
              hasUncommittedChanges: false,
              commitCount: 2,
            },
          },
        },
      };

      const action: WorktreeAction = {
        type: 'WORKTREE_SET_STATUS',
        payload: {
          sessionId: 'session_123',
          status: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'session/session_123',
              baseCommit: 'abc123',
              path: '/path/to/.worktrees/session_123',
              hasUncommittedChanges: true, // Changed
              commitCount: 5, // Changed
            },
          },
        },
      };

      const state = worktreeReducer(initialStateWithWorktree, action);
      expect(state.sessionWorktrees['session_123']?.worktree?.hasUncommittedChanges).toBe(true);
      expect(state.sessionWorktrees['session_123']?.worktree?.commitCount).toBe(5);
    });
  });

  describe('WORKTREE_SET_LOADING', () => {
    it('should set loading state', () => {
      const action: WorktreeAction = {
        type: 'WORKTREE_SET_LOADING',
        payload: true,
      };

      const state = worktreeReducer(initialWorktreeState, action);
      expect(state.isLoading).toBe(true);
    });

    it('should clear loading state', () => {
      const loadingState: WorktreeState = {
        ...initialWorktreeState,
        isLoading: true,
      };

      const action: WorktreeAction = {
        type: 'WORKTREE_SET_LOADING',
        payload: false,
      };

      const state = worktreeReducer(loadingState, action);
      expect(state.isLoading).toBe(false);
    });
  });

  describe('WORKTREE_SET_ERROR', () => {
    it('should set error message', () => {
      const action: WorktreeAction = {
        type: 'WORKTREE_SET_ERROR',
        payload: 'Failed to fetch worktree status',
      };

      const state = worktreeReducer(initialWorktreeState, action);
      expect(state.error).toBe('Failed to fetch worktree status');
    });

    it('should clear error message', () => {
      const errorState: WorktreeState = {
        ...initialWorktreeState,
        error: 'Previous error',
      };

      const action: WorktreeAction = {
        type: 'WORKTREE_SET_ERROR',
        payload: null,
      };

      const state = worktreeReducer(errorState, action);
      expect(state.error).toBeNull();
    });
  });

  describe('WORKTREE_SET_ALL', () => {
    it('should set all worktrees', () => {
      const action: WorktreeAction = {
        type: 'WORKTREE_SET_ALL',
        payload: [
          { path: '/path/to/repo', branch: 'main' },
          { path: '/path/to/.worktrees/session1', branch: 'session/session1', sessionId: 'session1' },
          { path: '/path/to/.worktrees/session2', branch: 'session/session2', sessionId: 'session2' },
        ],
      };

      const state = worktreeReducer(initialWorktreeState, action);
      expect(state.allWorktrees).toHaveLength(3);
      expect(state.allWorktrees[0]?.branch).toBe('main');
      expect(state.allWorktrees[1]?.sessionId).toBe('session1');
    });
  });

  describe('WORKTREE_REMOVE_SESSION', () => {
    it('should remove worktree status for a session', () => {
      const stateWithWorktrees: WorktreeState = {
        ...initialWorktreeState,
        sessionWorktrees: {
          session_123: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'session/session_123',
              baseCommit: 'abc123',
              path: '/path',
            },
          },
          session_456: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'session/session_456',
              baseCommit: 'def456',
              path: '/path2',
            },
          },
        },
      };

      const action: WorktreeAction = {
        type: 'WORKTREE_REMOVE_SESSION',
        payload: 'session_123',
      };

      const state = worktreeReducer(stateWithWorktrees, action);
      expect(state.sessionWorktrees['session_123']).toBeUndefined();
      expect(state.sessionWorktrees['session_456']).toBeDefined();
    });
  });

  describe('WORKTREE_RESET', () => {
    it('should reset to initial state', () => {
      const modifiedState: WorktreeState = {
        sessionWorktrees: {
          session_123: {
            hasWorktree: true,
            worktree: {
              isolated: true,
              branch: 'test',
              baseCommit: 'abc',
              path: '/test',
            },
          },
        },
        allWorktrees: [{ path: '/test', branch: 'test' }],
        isLoading: true,
        error: 'Some error',
      };

      const action: WorktreeAction = {
        type: 'WORKTREE_RESET',
      };

      const state = worktreeReducer(modifiedState, action);
      expect(state).toEqual(initialWorktreeState);
    });
  });
});

// =============================================================================
// Hook Tests
// =============================================================================

describe('useWorktreeStore', () => {
  // Mock RPC client
  const mockRpcClient = {
    worktreeGetStatus: vi.fn(),
    worktreeCommit: vi.fn(),
    worktreeMerge: vi.fn(),
    worktreeList: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('fetchWorktreeStatus', () => {
    it('should fetch and store worktree status', async () => {
      mockRpcClient.worktreeGetStatus.mockResolvedValue({
        hasWorktree: true,
        worktree: {
          isolated: true,
          branch: 'session/test',
          baseCommit: 'abc123',
          path: '/test/path',
          hasUncommittedChanges: false,
          commitCount: 0,
        },
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      await act(async () => {
        await result.current.fetchWorktreeStatus('session_123');
      });

      expect(mockRpcClient.worktreeGetStatus).toHaveBeenCalledWith({ sessionId: 'session_123' });
      expect(result.current.state.sessionWorktrees['session_123']?.hasWorktree).toBe(true);
    });

    it('should handle fetch error', async () => {
      mockRpcClient.worktreeGetStatus.mockRejectedValue(new Error('Network error'));

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      await act(async () => {
        await result.current.fetchWorktreeStatus('session_123');
      });

      expect(result.current.state.error).toBe('Network error');
    });

    it('should set loading state during fetch', async () => {
      let resolvePromise: () => void;
      const pendingPromise = new Promise<void>((resolve) => {
        resolvePromise = resolve;
      });

      mockRpcClient.worktreeGetStatus.mockImplementation(() => pendingPromise.then(() => ({
        hasWorktree: false,
      })));

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      // Start fetch (don't await)
      act(() => {
        void result.current.fetchWorktreeStatus('session_123');
      });

      // Check loading is true
      expect(result.current.state.isLoading).toBe(true);

      // Resolve the promise
      await act(async () => {
        resolvePromise!();
        await pendingPromise;
      });

      // Check loading is false
      expect(result.current.state.isLoading).toBe(false);
    });
  });

  describe('commitChanges', () => {
    it('should commit worktree changes', async () => {
      mockRpcClient.worktreeCommit.mockResolvedValue({
        success: true,
        commitHash: 'abc123def',
        filesChanged: ['file1.ts', 'file2.ts'],
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      let commitResult: any;
      await act(async () => {
        commitResult = await result.current.commitChanges('session_123', 'Test commit');
      });

      expect(mockRpcClient.worktreeCommit).toHaveBeenCalledWith({
        sessionId: 'session_123',
        message: 'Test commit',
      });
      expect(commitResult.success).toBe(true);
      expect(commitResult.commitHash).toBe('abc123def');
    });

    it('should handle commit failure', async () => {
      mockRpcClient.worktreeCommit.mockResolvedValue({
        success: false,
        error: 'No changes to commit',
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      let commitResult: any;
      await act(async () => {
        commitResult = await result.current.commitChanges('session_123', 'Test commit');
      });

      expect(commitResult.success).toBe(false);
      expect(commitResult.error).toBe('No changes to commit');
    });
  });

  describe('mergeWorktree', () => {
    it('should merge worktree to target branch', async () => {
      mockRpcClient.worktreeMerge.mockResolvedValue({
        success: true,
        mergeCommit: 'merge123',
        conflicts: [],
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      let mergeResult: any;
      await act(async () => {
        mergeResult = await result.current.mergeWorktree('session_123', 'main', 'squash');
      });

      expect(mockRpcClient.worktreeMerge).toHaveBeenCalledWith({
        sessionId: 'session_123',
        targetBranch: 'main',
        strategy: 'squash',
      });
      expect(mergeResult.success).toBe(true);
      expect(mergeResult.mergeCommit).toBe('merge123');
    });

    it('should handle merge conflicts', async () => {
      mockRpcClient.worktreeMerge.mockResolvedValue({
        success: false,
        conflicts: ['file1.ts', 'file2.ts'],
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      let mergeResult: any;
      await act(async () => {
        mergeResult = await result.current.mergeWorktree('session_123', 'main');
      });

      expect(mergeResult.success).toBe(false);
      expect(mergeResult.conflicts).toEqual(['file1.ts', 'file2.ts']);
    });
  });

  describe('fetchAllWorktrees', () => {
    it('should fetch and store all worktrees', async () => {
      mockRpcClient.worktreeList.mockResolvedValue({
        worktrees: [
          { path: '/repo', branch: 'main' },
          { path: '/.worktrees/s1', branch: 'session/s1', sessionId: 's1' },
        ],
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      await act(async () => {
        await result.current.fetchAllWorktrees();
      });

      expect(result.current.state.allWorktrees).toHaveLength(2);
      expect(result.current.state.allWorktrees[0]?.branch).toBe('main');
    });
  });

  describe('getWorktreeForSession', () => {
    it('should return worktree status for session', async () => {
      mockRpcClient.worktreeGetStatus.mockResolvedValue({
        hasWorktree: true,
        worktree: {
          isolated: true,
          branch: 'session/test',
          baseCommit: 'abc123',
          path: '/test/path',
        },
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      await act(async () => {
        await result.current.fetchWorktreeStatus('session_123');
      });

      const status = result.current.getWorktreeForSession('session_123');
      expect(status?.hasWorktree).toBe(true);
      expect(status?.worktree?.branch).toBe('session/test');
    });

    it('should return undefined for unknown session', () => {
      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      const status = result.current.getWorktreeForSession('unknown');
      expect(status).toBeUndefined();
    });
  });

  describe('clearWorktreeForSession', () => {
    it('should clear worktree status for session', async () => {
      mockRpcClient.worktreeGetStatus.mockResolvedValue({
        hasWorktree: true,
        worktree: {
          isolated: true,
          branch: 'session/test',
          baseCommit: 'abc123',
          path: '/test/path',
        },
      });

      const { result } = renderHook(() => useWorktreeStore(mockRpcClient as any));

      await act(async () => {
        await result.current.fetchWorktreeStatus('session_123');
      });

      expect(result.current.getWorktreeForSession('session_123')).toBeDefined();

      act(() => {
        result.current.clearWorktreeForSession('session_123');
      });

      expect(result.current.getWorktreeForSession('session_123')).toBeUndefined();
    });
  });
});
