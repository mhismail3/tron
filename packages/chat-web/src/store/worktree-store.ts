/**
 * @fileoverview Worktree State Management Store
 *
 * Manages worktree status for sessions, including fetching status,
 * committing changes, and merging worktrees.
 */

import { useReducer, useCallback, useMemo } from 'react';
import type { RpcClient } from '../rpc/client.js';
import type {
  WorktreeGetStatusResult,
  WorktreeCommitResult,
  WorktreeMergeResult,
} from '@tron/core/browser';

// =============================================================================
// Types
// =============================================================================

export interface WorktreeInfo {
  isolated: boolean;
  branch: string;
  baseCommit: string;
  path: string;
  hasUncommittedChanges?: boolean;
  commitCount?: number;
}

export interface WorktreeStatus {
  hasWorktree: boolean;
  worktree?: WorktreeInfo;
}

export interface WorktreeListItem {
  path: string;
  branch: string;
  sessionId?: string;
}

export interface WorktreeState {
  /** Worktree status keyed by session ID */
  sessionWorktrees: Record<string, WorktreeStatus>;
  /** All worktrees in the repository */
  allWorktrees: WorktreeListItem[];
  /** Loading state */
  isLoading: boolean;
  /** Error message */
  error: string | null;
}

export type WorktreeAction =
  | { type: 'WORKTREE_SET_STATUS'; payload: { sessionId: string; status: WorktreeStatus } }
  | { type: 'WORKTREE_SET_LOADING'; payload: boolean }
  | { type: 'WORKTREE_SET_ERROR'; payload: string | null }
  | { type: 'WORKTREE_SET_ALL'; payload: WorktreeListItem[] }
  | { type: 'WORKTREE_REMOVE_SESSION'; payload: string }
  | { type: 'WORKTREE_RESET' };

// =============================================================================
// Initial State
// =============================================================================

export const initialWorktreeState: WorktreeState = {
  sessionWorktrees: {},
  allWorktrees: [],
  isLoading: false,
  error: null,
};

// =============================================================================
// Reducer
// =============================================================================

export function worktreeReducer(
  state: WorktreeState = initialWorktreeState,
  action: WorktreeAction,
): WorktreeState {
  switch (action.type) {
    case 'WORKTREE_SET_STATUS':
      return {
        ...state,
        sessionWorktrees: {
          ...state.sessionWorktrees,
          [action.payload.sessionId]: action.payload.status,
        },
      };

    case 'WORKTREE_SET_LOADING':
      return {
        ...state,
        isLoading: action.payload,
      };

    case 'WORKTREE_SET_ERROR':
      return {
        ...state,
        error: action.payload,
      };

    case 'WORKTREE_SET_ALL':
      return {
        ...state,
        allWorktrees: action.payload,
      };

    case 'WORKTREE_REMOVE_SESSION': {
      const { [action.payload]: _, ...remainingWorktrees } = state.sessionWorktrees;
      return {
        ...state,
        sessionWorktrees: remainingWorktrees,
      };
    }

    case 'WORKTREE_RESET':
      return initialWorktreeState;

    default:
      return state;
  }
}

// =============================================================================
// Hook
// =============================================================================

export interface UseWorktreeStoreReturn {
  state: WorktreeState;
  fetchWorktreeStatus: (sessionId: string) => Promise<WorktreeStatus | null>;
  commitChanges: (sessionId: string, message: string) => Promise<WorktreeCommitResult>;
  mergeWorktree: (
    sessionId: string,
    targetBranch: string,
    strategy?: 'merge' | 'rebase' | 'squash',
  ) => Promise<WorktreeMergeResult>;
  fetchAllWorktrees: () => Promise<void>;
  getWorktreeForSession: (sessionId: string) => WorktreeStatus | undefined;
  clearWorktreeForSession: (sessionId: string) => void;
  clearError: () => void;
}

export function useWorktreeStore(rpcClient: RpcClient | null): UseWorktreeStoreReturn {
  const [state, dispatch] = useReducer(worktreeReducer, initialWorktreeState);

  const fetchWorktreeStatus = useCallback(
    async (sessionId: string): Promise<WorktreeStatus | null> => {
      if (!rpcClient) {
        dispatch({ type: 'WORKTREE_SET_ERROR', payload: 'No RPC connection' });
        return null;
      }

      dispatch({ type: 'WORKTREE_SET_LOADING', payload: true });
      dispatch({ type: 'WORKTREE_SET_ERROR', payload: null });

      try {
        const result: WorktreeGetStatusResult = await rpcClient.worktreeGetStatus({ sessionId });
        const status: WorktreeStatus = {
          hasWorktree: result.hasWorktree,
          worktree: result.worktree
            ? {
                isolated: result.worktree.isolated,
                branch: result.worktree.branch,
                baseCommit: result.worktree.baseCommit,
                path: result.worktree.path,
                hasUncommittedChanges: result.worktree.hasUncommittedChanges,
                commitCount: result.worktree.commitCount,
              }
            : undefined,
        };

        dispatch({
          type: 'WORKTREE_SET_STATUS',
          payload: { sessionId, status },
        });

        return status;
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Failed to fetch worktree status';
        dispatch({ type: 'WORKTREE_SET_ERROR', payload: message });
        return null;
      } finally {
        dispatch({ type: 'WORKTREE_SET_LOADING', payload: false });
      }
    },
    [rpcClient],
  );

  const commitChanges = useCallback(
    async (sessionId: string, message: string): Promise<WorktreeCommitResult> => {
      if (!rpcClient) {
        return { success: false, error: 'No RPC connection' };
      }

      dispatch({ type: 'WORKTREE_SET_LOADING', payload: true });
      dispatch({ type: 'WORKTREE_SET_ERROR', payload: null });

      try {
        const result = await rpcClient.worktreeCommit({ sessionId, message });

        // Refresh worktree status after commit
        if (result.success) {
          await fetchWorktreeStatus(sessionId);
        }

        return result;
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Commit failed';
        dispatch({ type: 'WORKTREE_SET_ERROR', payload: errorMessage });
        return { success: false, error: errorMessage };
      } finally {
        dispatch({ type: 'WORKTREE_SET_LOADING', payload: false });
      }
    },
    [rpcClient, fetchWorktreeStatus],
  );

  const mergeWorktree = useCallback(
    async (
      sessionId: string,
      targetBranch: string,
      strategy?: 'merge' | 'rebase' | 'squash',
    ): Promise<WorktreeMergeResult> => {
      if (!rpcClient) {
        return { success: false, error: 'No RPC connection' };
      }

      dispatch({ type: 'WORKTREE_SET_LOADING', payload: true });
      dispatch({ type: 'WORKTREE_SET_ERROR', payload: null });

      try {
        const result = await rpcClient.worktreeMerge({ sessionId, targetBranch, strategy });
        return result;
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Merge failed';
        dispatch({ type: 'WORKTREE_SET_ERROR', payload: errorMessage });
        return { success: false, error: errorMessage };
      } finally {
        dispatch({ type: 'WORKTREE_SET_LOADING', payload: false });
      }
    },
    [rpcClient],
  );

  const fetchAllWorktrees = useCallback(async (): Promise<void> => {
    if (!rpcClient) {
      dispatch({ type: 'WORKTREE_SET_ERROR', payload: 'No RPC connection' });
      return;
    }

    dispatch({ type: 'WORKTREE_SET_LOADING', payload: true });
    dispatch({ type: 'WORKTREE_SET_ERROR', payload: null });

    try {
      const result = await rpcClient.worktreeList();
      dispatch({ type: 'WORKTREE_SET_ALL', payload: result.worktrees });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to fetch worktrees';
      dispatch({ type: 'WORKTREE_SET_ERROR', payload: message });
    } finally {
      dispatch({ type: 'WORKTREE_SET_LOADING', payload: false });
    }
  }, [rpcClient]);

  const getWorktreeForSession = useCallback(
    (sessionId: string): WorktreeStatus | undefined => {
      return state.sessionWorktrees[sessionId];
    },
    [state.sessionWorktrees],
  );

  const clearWorktreeForSession = useCallback((sessionId: string): void => {
    dispatch({ type: 'WORKTREE_REMOVE_SESSION', payload: sessionId });
  }, []);

  const clearError = useCallback((): void => {
    dispatch({ type: 'WORKTREE_SET_ERROR', payload: null });
  }, []);

  return useMemo(
    () => ({
      state,
      fetchWorktreeStatus,
      commitChanges,
      mergeWorktree,
      fetchAllWorktrees,
      getWorktreeForSession,
      clearWorktreeForSession,
      clearError,
    }),
    [
      state,
      fetchWorktreeStatus,
      commitChanges,
      mergeWorktree,
      fetchAllWorktrees,
      getWorktreeForSession,
      clearWorktreeForSession,
      clearError,
    ],
  );
}
