/**
 * @fileoverview Event Store React Hook
 *
 * React hook for interacting with the IndexedDB event store.
 * Provides:
 * - Local event caching
 * - Server sync via RPC
 * - State reconstruction
 * - Tree visualization
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import {
  EventDB,
  getEventDB,
  type CachedEvent,
  type CachedSession,
  type EventTreeNode,
  type SyncState,
} from '../store/event-db.js';
import type { DisplayMessage } from '../store/types.js';

// =============================================================================
// Types
// =============================================================================

export interface UseEventStoreOptions {
  /** RPC call function for server communication */
  rpcCall?: <T>(method: string, params?: unknown) => Promise<T>;
  /** Enable auto-sync with server */
  autoSync?: boolean;
  /** Sync interval in milliseconds (default: 30000) */
  syncInterval?: number;
}

export interface EventStoreState {
  /** Whether the event store is initialized */
  isInitialized: boolean;
  /** Whether currently syncing with server */
  isSyncing: boolean;
  /** Last sync error, if any */
  syncError: string | null;
  /** Number of pending events to sync */
  pendingEventCount: number;
}

export interface UseEventStoreReturn {
  /** Current state */
  state: EventStoreState;

  // Session Operations
  /** Get a session by ID */
  getSession: (sessionId: string) => Promise<CachedSession | null>;
  /** Get all sessions */
  getSessions: () => Promise<CachedSession[]>;
  /** Cache a session locally */
  cacheSession: (session: CachedSession) => Promise<void>;
  /** Remove a session from cache */
  removeSession: (sessionId: string) => Promise<void>;

  // Event Operations
  /** Get events for a session */
  getEvents: (sessionId: string) => Promise<CachedEvent[]>;
  /** Cache events locally */
  cacheEvents: (events: CachedEvent[]) => Promise<void>;
  /** Get ancestors of an event */
  getAncestors: (eventId: string) => Promise<CachedEvent[]>;

  // State Reconstruction
  /** Get messages at session head */
  getMessagesAtHead: (sessionId: string) => Promise<DisplayMessage[]>;
  /** Get full state at session head */
  getStateAtHead: (sessionId: string) => Promise<{
    messages: DisplayMessage[];
    tokenUsage: { input: number; output: number };
    turnCount: number;
  }>;

  // Tree Operations
  /** Get tree visualization for a session */
  getTree: (sessionId: string) => Promise<EventTreeNode[]>;

  // Fork Operations
  /** Fork session from an event, creating a new branch */
  fork: (sessionId: string, fromEventId?: string) => Promise<{
    newSessionId: string;
    rootEventId: string;
  } | null>;
  /** Get messages at a specific event (for preview) */
  getMessagesAtEvent: (eventId: string) => Promise<DisplayMessage[]>;

  // Sync Operations
  /** Sync with server */
  sync: (sessionId?: string) => Promise<void>;
  /** Force full sync */
  fullSync: (sessionId: string) => Promise<void>;

  // Utilities
  /** Clear all cached data */
  clear: () => Promise<void>;
}

// =============================================================================
// Hook Implementation
// =============================================================================

export function useEventStore(options: UseEventStoreOptions = {}): UseEventStoreReturn {
  const { rpcCall, autoSync = true, syncInterval = 30000 } = options;

  const dbRef = useRef<EventDB | null>(null);
  const syncTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const [state, setState] = useState<EventStoreState>({
    isInitialized: false,
    isSyncing: false,
    syncError: null,
    pendingEventCount: 0,
  });

  // ===========================================================================
  // Initialization
  // ===========================================================================

  useEffect(() => {
    const initDB = async () => {
      try {
        const db = getEventDB();
        await db.init();
        dbRef.current = db;
        setState((s) => ({ ...s, isInitialized: true }));
      } catch (err) {
        console.error('[EventStore] Failed to initialize:', err);
        setState((s) => ({
          ...s,
          syncError: err instanceof Error ? err.message : 'Failed to initialize',
        }));
      }
    };

    initDB();

    return () => {
      if (syncTimerRef.current) {
        clearInterval(syncTimerRef.current);
      }
    };
  }, []);

  // ===========================================================================
  // Auto Sync
  // ===========================================================================

  useEffect(() => {
    if (!autoSync || !rpcCall || !state.isInitialized) return;

    const doSync = async () => {
      try {
        await sync();
      } catch (err) {
        console.error('[EventStore] Auto-sync failed:', err);
      }
    };

    // Initial sync
    doSync();

    // Set up interval
    syncTimerRef.current = setInterval(doSync, syncInterval);

    return () => {
      if (syncTimerRef.current) {
        clearInterval(syncTimerRef.current);
        syncTimerRef.current = null;
      }
    };
  }, [autoSync, rpcCall, state.isInitialized, syncInterval]);

  // ===========================================================================
  // Session Operations
  // ===========================================================================

  const getSession = useCallback(async (sessionId: string): Promise<CachedSession | null> => {
    if (!dbRef.current) return null;
    return dbRef.current.getSession(sessionId);
  }, []);

  const getSessions = useCallback(async (): Promise<CachedSession[]> => {
    if (!dbRef.current) return [];
    return dbRef.current.getAllSessions();
  }, []);

  const cacheSession = useCallback(async (session: CachedSession): Promise<void> => {
    if (!dbRef.current) return;
    await dbRef.current.putSession(session);
  }, []);

  const removeSession = useCallback(async (sessionId: string): Promise<void> => {
    if (!dbRef.current) return;
    await dbRef.current.deleteSession(sessionId);
    await dbRef.current.deleteEventsBySession(sessionId);
  }, []);

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  const getEvents = useCallback(async (sessionId: string): Promise<CachedEvent[]> => {
    if (!dbRef.current) return [];
    return dbRef.current.getEventsBySession(sessionId);
  }, []);

  const cacheEvents = useCallback(async (events: CachedEvent[]): Promise<void> => {
    if (!dbRef.current) return;
    await dbRef.current.putEvents(events);
  }, []);

  const getAncestors = useCallback(async (eventId: string): Promise<CachedEvent[]> => {
    if (!dbRef.current) return [];
    return dbRef.current.getAncestors(eventId);
  }, []);

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  const getMessagesAtHead = useCallback(async (sessionId: string): Promise<DisplayMessage[]> => {
    if (!dbRef.current) return [];

    const session = await dbRef.current.getSession(sessionId);
    if (!session?.headEventId) return [];

    const messages = await dbRef.current.getMessagesAt(session.headEventId);
    return messages.map((m, i) => ({
      id: `msg-${i}`,
      role: m.role as DisplayMessage['role'],
      content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content),
      timestamp: new Date().toISOString(),
    }));
  }, []);

  const getStateAtHead = useCallback(
    async (
      sessionId: string
    ): Promise<{
      messages: DisplayMessage[];
      tokenUsage: { input: number; output: number };
      turnCount: number;
    }> => {
      if (!dbRef.current) {
        return {
          messages: [],
          tokenUsage: { input: 0, output: 0 },
          turnCount: 0,
        };
      }

      const state = await dbRef.current.getStateAtHead(sessionId);
      const messages = state.messages.map((m, i) => ({
        id: `msg-${i}`,
        role: m.role as DisplayMessage['role'],
        content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content),
        timestamp: new Date().toISOString(),
      }));

      return {
        messages,
        tokenUsage: {
          input: state.tokenUsage.inputTokens,
          output: state.tokenUsage.outputTokens,
        },
        turnCount: state.turnCount,
      };
    },
    []
  );

  // ===========================================================================
  // Tree Operations
  // ===========================================================================

  const getTree = useCallback(async (sessionId: string): Promise<EventTreeNode[]> => {
    if (!dbRef.current) return [];
    return dbRef.current.buildTreeVisualization(sessionId);
  }, []);

  // ===========================================================================
  // Fork Operations
  // ===========================================================================

  const fork = useCallback(
    async (
      sessionId: string,
      fromEventId?: string
    ): Promise<{ newSessionId: string; rootEventId: string } | null> => {
      if (!rpcCall) {
        console.error('[EventStore] Cannot fork: no RPC connection');
        return null;
      }

      try {
        const response = await rpcCall<{
          newSessionId: string;
          rootEventId: string;
          forkedFromEventId: string;
          forkedFromSessionId: string;
        }>('session.fork', {
          sessionId,
          fromEventId,
        });

        // Sync the new session to get its events locally
        if (response.newSessionId) {
          await fullSync(response.newSessionId);
        }

        return {
          newSessionId: response.newSessionId,
          rootEventId: response.rootEventId,
        };
      } catch (err) {
        console.error('[EventStore] Fork failed:', err);
        return null;
      }
    },
    [rpcCall]
  );

  const getMessagesAtEvent = useCallback(
    async (eventId: string): Promise<DisplayMessage[]> => {
      if (!dbRef.current) return [];

      const messages = await dbRef.current.getMessagesAt(eventId);
      return messages.map((m, i) => ({
        id: `msg-${i}`,
        role: m.role as DisplayMessage['role'],
        content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content),
        timestamp: new Date().toISOString(),
      }));
    },
    []
  );

  // ===========================================================================
  // Sync Operations
  // ===========================================================================

  const sync = useCallback(
    async (sessionId?: string): Promise<void> => {
      if (!dbRef.current || !rpcCall) return;

      setState((s) => ({ ...s, isSyncing: true, syncError: null }));

      try {
        if (sessionId) {
          // Sync specific session
          await syncSession(sessionId);
        } else {
          // Sync all sessions
          const sessions = await dbRef.current.getAllSessions();
          for (const session of sessions) {
            await syncSession(session.id);
          }
        }

        setState((s) => ({ ...s, isSyncing: false }));
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Sync failed';
        console.error('[EventStore] Sync error:', err);
        setState((s) => ({ ...s, isSyncing: false, syncError: errorMessage }));
      }
    },
    [rpcCall]
  );

  const syncSession = async (sessionId: string): Promise<void> => {
    if (!dbRef.current || !rpcCall) return;

    const db = dbRef.current;

    // Get sync state
    let syncState = await db.getSyncState(sessionId);
    if (!syncState) {
      syncState = {
        key: sessionId,
        lastSyncedEventId: null,
        lastSyncTimestamp: null,
        pendingEventIds: [],
      };
    }

    // Fetch new events from server
    const response = await rpcCall<{
      events: CachedEvent[];
      session?: CachedSession;
    }>('events.getSince', {
      sessionId,
      sinceEventId: syncState.lastSyncedEventId,
    });

    if (response.events && response.events.length > 0) {
      // Cache new events
      await db.putEvents(response.events);

      // Update sync state
      const lastEvent = response.events[response.events.length - 1]!;
      await db.putSyncState({
        ...syncState,
        lastSyncedEventId: lastEvent.id,
        lastSyncTimestamp: new Date().toISOString(),
      });
    }

    // Update session if provided
    if (response.session) {
      await db.putSession(response.session);
    }
  };

  const fullSync = useCallback(
    async (sessionId: string): Promise<void> => {
      if (!dbRef.current || !rpcCall) return;

      setState((s) => ({ ...s, isSyncing: true, syncError: null }));

      try {
        // Clear existing events for this session
        await dbRef.current.deleteEventsBySession(sessionId);

        // Reset sync state
        await dbRef.current.putSyncState({
          key: sessionId,
          lastSyncedEventId: null,
          lastSyncTimestamp: null,
          pendingEventIds: [],
        });

        // Fetch all events
        const response = await rpcCall<{
          events: CachedEvent[];
          session: CachedSession;
        }>('events.getAll', { sessionId });

        if (response.events) {
          await dbRef.current.putEvents(response.events);
        }

        if (response.session) {
          await dbRef.current.putSession(response.session);
        }

        // Update sync state
        if (response.events && response.events.length > 0) {
          const lastEvent = response.events[response.events.length - 1]!;
          await dbRef.current.putSyncState({
            key: sessionId,
            lastSyncedEventId: lastEvent.id,
            lastSyncTimestamp: new Date().toISOString(),
            pendingEventIds: [],
          });
        }

        setState((s) => ({ ...s, isSyncing: false }));
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Full sync failed';
        console.error('[EventStore] Full sync error:', err);
        setState((s) => ({ ...s, isSyncing: false, syncError: errorMessage }));
      }
    },
    [rpcCall]
  );

  // ===========================================================================
  // Utilities
  // ===========================================================================

  const clear = useCallback(async (): Promise<void> => {
    if (!dbRef.current) return;
    await dbRef.current.clear();
  }, []);

  // ===========================================================================
  // Return
  // ===========================================================================

  return {
    state,
    getSession,
    getSessions,
    cacheSession,
    removeSession,
    getEvents,
    cacheEvents,
    getAncestors,
    getMessagesAtHead,
    getStateAtHead,
    getTree,
    fork,
    getMessagesAtEvent,
    sync,
    fullSync,
    clear,
  };
}
