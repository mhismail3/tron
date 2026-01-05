/**
 * @fileoverview Tests for useEventStore hook
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { useEventStore } from '../../src/hooks/useEventStore.js';
import { getEventDB, type CachedEvent, type CachedSession } from '../../src/store/event-db.js';

describe('useEventStore', () => {
  beforeEach(async () => {
    // Initialize and clear the database before each test
    const db = getEventDB();
    await db.init();
    await db.clear();
  });

  afterEach(async () => {
    const db = getEventDB();
    await db.clear();
    db.close();
  });

  // ===========================================================================
  // Initialization
  // ===========================================================================

  describe('Initialization', () => {
    it('should start with uninitialized state', () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      // Initially not initialized
      expect(result.current.state.isInitialized).toBe(false);
    });

    it('should become initialized after mount', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });
    });

    it('should start with no sync error', () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      expect(result.current.state.syncError).toBeNull();
    });
  });

  // ===========================================================================
  // Session Operations
  // ===========================================================================

  describe('Session Operations', () => {
    const testSession: CachedSession = {
      id: 'session-1',
      workspaceId: 'ws-1',
      rootEventId: 'event-1',
      headEventId: 'event-3',
      status: 'active',
      title: 'Test Session',
      model: 'claude-sonnet-4',
      provider: 'anthropic',
      workingDirectory: '/test/project',
      createdAt: '2024-01-01T00:00:00Z',
      lastActivityAt: '2024-01-01T01:00:00Z',
      eventCount: 3,
      messageCount: 2,
    };

    it('should cache and retrieve a session', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      await act(async () => {
        await result.current.cacheSession(testSession);
      });

      let retrieved: CachedSession | null = null;
      await act(async () => {
        retrieved = await result.current.getSession('session-1');
      });

      expect(retrieved).toEqual(testSession);
    });

    it('should get all sessions', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      const session2 = { ...testSession, id: 'session-2', title: 'Second Session' };

      await act(async () => {
        await result.current.cacheSession(testSession);
        await result.current.cacheSession(session2);
      });

      let sessions: CachedSession[] = [];
      await act(async () => {
        sessions = await result.current.getSessions();
      });

      expect(sessions.length).toBe(2);
    });

    it('should remove a session', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      await act(async () => {
        await result.current.cacheSession(testSession);
        await result.current.removeSession('session-1');
      });

      let retrieved: CachedSession | null = null;
      await act(async () => {
        retrieved = await result.current.getSession('session-1');
      });

      expect(retrieved).toBeNull();
    });
  });

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  describe('Event Operations', () => {
    const testEvents: CachedEvent[] = [
      {
        id: 'event-1',
        parentId: null,
        sessionId: 'session-1',
        workspaceId: 'ws-1',
        type: 'session.start',
        timestamp: '2024-01-01T00:00:00Z',
        sequence: 0,
        payload: {},
      },
      {
        id: 'event-2',
        parentId: 'event-1',
        sessionId: 'session-1',
        workspaceId: 'ws-1',
        type: 'message.user',
        timestamp: '2024-01-01T00:01:00Z',
        sequence: 1,
        payload: { content: 'Hello!' },
      },
    ];

    it('should cache and retrieve events', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      await act(async () => {
        await result.current.cacheEvents(testEvents);
      });

      let events: CachedEvent[] = [];
      await act(async () => {
        events = await result.current.getEvents('session-1');
      });

      expect(events.length).toBe(2);
    });

    it('should get ancestors of an event', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      await act(async () => {
        await result.current.cacheEvents(testEvents);
      });

      let ancestors: CachedEvent[] = [];
      await act(async () => {
        ancestors = await result.current.getAncestors('event-2');
      });

      expect(ancestors.length).toBe(2);
      expect(ancestors[0]!.id).toBe('event-1');
      expect(ancestors[1]!.id).toBe('event-2');
    });
  });

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  describe('State Reconstruction', () => {
    it('should get messages at session head', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        status: 'active',
        title: null,
        model: 'claude-sonnet-4',
        provider: 'anthropic',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:02:00Z',
        eventCount: 3,
        messageCount: 2,
      };

      const events: CachedEvent[] = [
        {
          id: 'event-1',
          parentId: null,
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'session.start',
          timestamp: '2024-01-01T00:00:00Z',
          sequence: 0,
          payload: {},
        },
        {
          id: 'event-2',
          parentId: 'event-1',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.user',
          timestamp: '2024-01-01T00:01:00Z',
          sequence: 1,
          payload: { content: 'Hello!' },
        },
        {
          id: 'event-3',
          parentId: 'event-2',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.assistant',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Hi there!' },
        },
      ];

      await act(async () => {
        await result.current.cacheSession(session);
        await result.current.cacheEvents(events);
      });

      let messages: any[] = [];
      await act(async () => {
        messages = await result.current.getMessagesAtHead('session-1');
      });

      expect(messages.length).toBe(2);
      expect(messages[0].role).toBe('user');
      expect(messages[0].content).toBe('Hello!');
      expect(messages[1].role).toBe('assistant');
      expect(messages[1].content).toBe('Hi there!');
    });

    it('should get messages at a specific event', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      const events: CachedEvent[] = [
        {
          id: 'event-1',
          parentId: null,
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'session.start',
          timestamp: '2024-01-01T00:00:00Z',
          sequence: 0,
          payload: {},
        },
        {
          id: 'event-2',
          parentId: 'event-1',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.user',
          timestamp: '2024-01-01T00:01:00Z',
          sequence: 1,
          payload: { content: 'First message' },
        },
        {
          id: 'event-3',
          parentId: 'event-2',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.assistant',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Response' },
        },
        {
          id: 'event-4',
          parentId: 'event-3',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.user',
          timestamp: '2024-01-01T00:03:00Z',
          sequence: 3,
          payload: { content: 'Second message' },
        },
      ];

      await act(async () => {
        await result.current.cacheEvents(events);
      });

      // Get messages at event-3 (should only have 2 messages)
      let messagesAt3: any[] = [];
      await act(async () => {
        messagesAt3 = await result.current.getMessagesAtEvent('event-3');
      });

      expect(messagesAt3.length).toBe(2);
      expect(messagesAt3[0].content).toBe('First message');
      expect(messagesAt3[1].content).toBe('Response');
    });
  });

  // ===========================================================================
  // Tree Operations
  // ===========================================================================

  describe('Tree Operations', () => {
    it('should get tree visualization', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        status: 'active',
        title: null,
        model: 'claude-sonnet-4',
        provider: 'anthropic',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        eventCount: 3,
        messageCount: 2,
      };

      const events: CachedEvent[] = [
        {
          id: 'event-1',
          parentId: null,
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'session.start',
          timestamp: '2024-01-01T00:00:00Z',
          sequence: 0,
          payload: {},
        },
        {
          id: 'event-2',
          parentId: 'event-1',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.user',
          timestamp: '2024-01-01T00:01:00Z',
          sequence: 1,
          payload: { content: 'Hello' },
        },
        {
          id: 'event-3',
          parentId: 'event-2',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.assistant',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Hi' },
        },
      ];

      await act(async () => {
        await result.current.cacheSession(session);
        await result.current.cacheEvents(events);
      });

      let tree: any[] = [];
      await act(async () => {
        tree = await result.current.getTree('session-1');
      });

      expect(tree.length).toBe(3);
      expect(tree[0].id).toBe('event-1');
      expect(tree[0].depth).toBe(0);
      expect(tree.find((n: any) => n.id === 'event-3')?.isHead).toBe(true);
    });
  });

  // ===========================================================================
  // Fork/Rewind Operations
  // ===========================================================================

  describe('Fork/Rewind Operations', () => {
    it('should fail fork without RPC connection', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      let forkResult: any = null;
      await act(async () => {
        forkResult = await result.current.fork('session-1', 'event-2');
      });

      expect(forkResult).toBeNull();
    });

    it('should call RPC for fork when connected', async () => {
      const mockRpcCall = vi.fn().mockResolvedValue({
        newSessionId: 'session-2',
        rootEventId: 'event-fork-1',
        forkedFromEventId: 'event-2',
        forkedFromSessionId: 'session-1',
      });

      const { result } = renderHook(() =>
        useEventStore({ rpcCall: mockRpcCall, autoSync: false })
      );

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      let forkResult: any = null;
      await act(async () => {
        forkResult = await result.current.fork('session-1', 'event-2');
      });

      expect(mockRpcCall).toHaveBeenCalledWith('session.fork', {
        sessionId: 'session-1',
        fromEventId: 'event-2',
      });
      expect(forkResult?.newSessionId).toBe('session-2');
      expect(forkResult?.rootEventId).toBe('event-fork-1');
    });

    it('should fail rewind without RPC connection', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      let rewindResult: boolean = true;
      await act(async () => {
        rewindResult = await result.current.rewind('session-1', 'event-2');
      });

      expect(rewindResult).toBe(false);
    });

    it('should call RPC for rewind when connected', async () => {
      const mockRpcCall = vi.fn().mockResolvedValue({});

      const { result } = renderHook(() =>
        useEventStore({ rpcCall: mockRpcCall, autoSync: false })
      );

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      // Set up a session to rewind
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        status: 'active',
        title: null,
        model: 'claude-sonnet-4',
        provider: 'anthropic',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        eventCount: 3,
        messageCount: 2,
      };

      await act(async () => {
        await result.current.cacheSession(session);
      });

      let rewindResult: boolean = false;
      await act(async () => {
        rewindResult = await result.current.rewind('session-1', 'event-2');
      });

      expect(mockRpcCall).toHaveBeenCalledWith('session.rewind', {
        sessionId: 'session-1',
        toEventId: 'event-2',
      });
      expect(rewindResult).toBe(true);

      // Check that session was updated locally
      let updatedSession: CachedSession | null = null;
      await act(async () => {
        updatedSession = await result.current.getSession('session-1');
      });

      expect(updatedSession?.headEventId).toBe('event-2');
    });
  });

  // ===========================================================================
  // Utilities
  // ===========================================================================

  describe('Utilities', () => {
    it('should clear all data', async () => {
      const { result } = renderHook(() => useEventStore({ autoSync: false }));

      await waitFor(() => {
        expect(result.current.state.isInitialized).toBe(true);
      });

      // Add some data
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-1',
        status: 'active',
        title: null,
        model: 'claude-sonnet-4',
        provider: 'anthropic',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        eventCount: 1,
        messageCount: 0,
      };

      await act(async () => {
        await result.current.cacheSession(session);
        await result.current.clear();
      });

      let sessions: CachedSession[] = [];
      await act(async () => {
        sessions = await result.current.getSessions();
      });

      expect(sessions.length).toBe(0);
    });
  });
});
