/**
 * @fileoverview Tests for useSessionHistory Hook
 *
 * Tests for the hook that loads session events from server
 * and provides tree visualization and fork functionality.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { useSessionHistory } from '../../src/hooks/useSessionHistory.js';
import type { CachedEvent } from '../../src/store/event-db.js';

// =============================================================================
// Mocks
// =============================================================================

const mockRpcCall = vi.fn();

function createMockEvent(
  id: string,
  type: string,
  parentId: string | null = null,
  options: Partial<CachedEvent> = {}
): CachedEvent {
  return {
    id,
    parentId,
    sessionId: 'session_1',
    workspaceId: 'workspace_1',
    type,
    timestamp: new Date().toISOString(),
    sequence: 0,
    payload: {},
    ...options,
  };
}

describe('useSessionHistory', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.resetAllMocks();
  });

  describe('initialization', () => {
    it('should start with empty events and not loading', () => {
      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: null, rpcCall: mockRpcCall })
      );

      expect(result.current.events).toEqual([]);
      expect(result.current.isLoading).toBe(false);
      expect(result.current.error).toBeNull();
    });

    it('should not fetch events when sessionId is null', () => {
      renderHook(() =>
        useSessionHistory({ sessionId: null, rpcCall: mockRpcCall })
      );

      expect(mockRpcCall).not.toHaveBeenCalled();
    });
  });

  describe('loading events', () => {
    it('should fetch events when sessionId is provided', async () => {
      const mockEvents = [
        createMockEvent('evt_1', 'session.start'),
        createMockEvent('evt_2', 'message.user', 'evt_1'),
        createMockEvent('evt_3', 'message.assistant', 'evt_2'),
      ];

      mockRpcCall.mockResolvedValueOnce({
        events: mockEvents,
        hasMore: false,
      });

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.events).toHaveLength(3);
      });

      expect(mockRpcCall).toHaveBeenCalledWith('events.getHistory', {
        sessionId: 'session_1',
      });
    });

    it('should set isLoading while fetching', async () => {
      let resolvePromise: (value: { events: CachedEvent[]; hasMore: boolean }) => void;
      mockRpcCall.mockReturnValue(
        new Promise((resolve) => {
          resolvePromise = resolve;
        })
      );

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      // Should be loading initially
      expect(result.current.isLoading).toBe(true);

      // Resolve the promise
      await act(async () => {
        resolvePromise!({ events: [], hasMore: false });
      });

      // Should no longer be loading
      expect(result.current.isLoading).toBe(false);
    });

    it('should handle fetch errors', async () => {
      mockRpcCall.mockRejectedValueOnce(new Error('Network error'));

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.error).toBe('Network error');
      });

      expect(result.current.isLoading).toBe(false);
      expect(result.current.events).toEqual([]);
    });

    it('should refetch when sessionId changes', async () => {
      const mockEvents1 = [createMockEvent('evt_1', 'session.start')];
      const mockEvents2 = [createMockEvent('evt_2', 'session.start')];

      mockRpcCall
        .mockResolvedValueOnce({ events: mockEvents1, hasMore: false })
        .mockResolvedValueOnce({ events: mockEvents2, hasMore: false });

      const { result, rerender } = renderHook(
        ({ sessionId }) =>
          useSessionHistory({ sessionId, rpcCall: mockRpcCall }),
        { initialProps: { sessionId: 'session_1' } }
      );

      await waitFor(() => {
        expect(result.current.events).toHaveLength(1);
      });

      rerender({ sessionId: 'session_2' });

      await waitFor(() => {
        expect(mockRpcCall).toHaveBeenCalledTimes(2);
      });

      expect(mockRpcCall).toHaveBeenLastCalledWith('events.getHistory', {
        sessionId: 'session_2',
      });
    });
  });

  describe('refresh', () => {
    it('should provide a refresh function', async () => {
      const mockEvents = [createMockEvent('evt_1', 'session.start')];
      mockRpcCall.mockResolvedValue({ events: mockEvents, hasMore: false });

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.events).toHaveLength(1);
      });

      // Call refresh
      await act(async () => {
        await result.current.refresh();
      });

      expect(mockRpcCall).toHaveBeenCalledTimes(2);
    });
  });

  describe('headEventId', () => {
    it('should expose headEventId from session', async () => {
      mockRpcCall.mockResolvedValueOnce({
        events: [createMockEvent('evt_1', 'session.start')],
        hasMore: false,
        headEventId: 'evt_head',
      });

      const { result } = renderHook(() =>
        useSessionHistory({
          sessionId: 'session_1',
          rpcCall: mockRpcCall,
          headEventId: 'evt_head',
        })
      );

      expect(result.current.headEventId).toBe('evt_head');
    });
  });

  describe('tree nodes conversion', () => {
    it('should convert events to tree nodes', async () => {
      const mockEvents = [
        createMockEvent('evt_1', 'session.start', null),
        createMockEvent('evt_2', 'message.user', 'evt_1', {
          payload: { content: 'Hello world' },
        }),
        createMockEvent('evt_3', 'message.assistant', 'evt_2'),
      ];

      mockRpcCall.mockResolvedValueOnce({
        events: mockEvents,
        hasMore: false,
        headEventId: 'evt_3',
      });

      const { result } = renderHook(() =>
        useSessionHistory({
          sessionId: 'session_1',
          rpcCall: mockRpcCall,
          headEventId: 'evt_3',
        })
      );

      await waitFor(() => {
        expect(result.current.treeNodes).toHaveLength(3);
      });

      const nodes = result.current.treeNodes;
      expect(nodes[0]).toMatchObject({
        id: 'evt_1',
        type: 'session.start',
        parentId: null,
      });
      expect(nodes[1]).toMatchObject({
        id: 'evt_2',
        type: 'message.user',
        parentId: 'evt_1',
      });
      expect(nodes[2]).toMatchObject({
        id: 'evt_3',
        type: 'message.assistant',
        isHead: true,
      });
    });

    it('should identify branch points', async () => {
      // Create a branching tree: evt_1 -> evt_2a AND evt_1 -> evt_2b
      const mockEvents = [
        createMockEvent('evt_1', 'session.start', null),
        createMockEvent('evt_2a', 'message.user', 'evt_1'),
        createMockEvent('evt_2b', 'message.user', 'evt_1'),
      ];

      mockRpcCall.mockResolvedValueOnce({
        events: mockEvents,
        hasMore: false,
        headEventId: 'evt_2a',
      });

      const { result } = renderHook(() =>
        useSessionHistory({
          sessionId: 'session_1',
          rpcCall: mockRpcCall,
          headEventId: 'evt_2a',
        })
      );

      await waitFor(() => {
        expect(result.current.treeNodes).toHaveLength(3);
      });

      const nodes = result.current.treeNodes;
      // evt_1 should be marked as a branch point (has 2 children)
      expect(nodes.find((n) => n.id === 'evt_1')?.isBranchPoint).toBe(true);
    });
  });

  describe('fork operation', () => {
    it('should call session.fork RPC', async () => {
      mockRpcCall
        .mockResolvedValueOnce({ events: [], hasMore: false })
        .mockResolvedValueOnce({
          newSessionId: 'session_new',
          rootEventId: 'evt_new_root',
          forkedFromEventId: 'evt_2',
          forkedFromSessionId: 'session_1',
        });

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      let forkResult: { newSessionId: string } | null = null;
      await act(async () => {
        forkResult = await result.current.fork('evt_2');
      });

      expect(mockRpcCall).toHaveBeenCalledWith('session.fork', {
        sessionId: 'session_1',
        fromEventId: 'evt_2',
      });
      expect(forkResult).toEqual(
        expect.objectContaining({ newSessionId: 'session_new' })
      );
    });

    it('should handle fork errors gracefully', async () => {
      mockRpcCall
        .mockResolvedValueOnce({ events: [], hasMore: false })
        .mockRejectedValueOnce(new Error('Fork failed'));

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      let forkResult: { newSessionId: string } | null = null;
      await act(async () => {
        forkResult = await result.current.fork('evt_2');
      });

      expect(forkResult).toBeNull();
      expect(result.current.error).toBe('Fork failed');
    });
  });

  describe('branches', () => {
    it('should fetch branches when requested', async () => {
      const mockBranches = {
        mainBranch: {
          sessionId: 'session_1',
          name: 'main',
          forkEventId: 'evt_1',
          headEventId: 'evt_5',
          messageCount: 5,
          createdAt: new Date().toISOString(),
          lastActivity: new Date().toISOString(),
        },
        forks: [
          {
            sessionId: 'session_2',
            name: 'experiment',
            forkEventId: 'evt_3',
            headEventId: 'evt_7',
            messageCount: 2,
            createdAt: new Date().toISOString(),
            lastActivity: new Date().toISOString(),
          },
        ],
      };

      mockRpcCall
        .mockResolvedValueOnce({ events: [], hasMore: false })
        .mockResolvedValueOnce(mockBranches);

      const { result } = renderHook(() =>
        useSessionHistory({
          sessionId: 'session_1',
          rpcCall: mockRpcCall,
          includeBranches: true,
        })
      );

      await waitFor(() => {
        expect(result.current.branches).not.toBeNull();
      });

      expect(mockRpcCall).toHaveBeenCalledWith('tree.getBranches', {
        sessionId: 'session_1',
      });
      expect(result.current.branches?.forks).toHaveLength(1);
    });
  });

  describe('branchCount', () => {
    it('should calculate branch count from tree nodes', async () => {
      // Create tree with one branch point
      const mockEvents = [
        createMockEvent('evt_1', 'session.start', null),
        createMockEvent('evt_2a', 'message.user', 'evt_1'),
        createMockEvent('evt_2b', 'message.user', 'evt_1'), // Branch
      ];

      mockRpcCall.mockResolvedValueOnce({
        events: mockEvents,
        hasMore: false,
      });

      const { result } = renderHook(() =>
        useSessionHistory({ sessionId: 'session_1', rpcCall: mockRpcCall })
      );

      await waitFor(() => {
        expect(result.current.treeNodes).toHaveLength(3);
      });

      expect(result.current.branchCount).toBe(1);
    });
  });
});
