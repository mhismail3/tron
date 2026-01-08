/**
 * @fileoverview Integration tests for IndexedDB EventDB
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventDB, type CachedEvent, type CachedSession } from '../../src/store/event-db.js';

describe('EventDB', () => {
  let db: EventDB;

  beforeEach(async () => {
    db = new EventDB();
    await db.init();
  });

  afterEach(async () => {
    await db.clear();
    db.close();
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
      title: 'Test Session',
      latestModel: 'claude-sonnet-4',
      workingDirectory: '/test/project',
      createdAt: '2024-01-01T00:00:00Z',
      lastActivityAt: '2024-01-01T01:00:00Z',
      endedAt: null,
      eventCount: 3,
      messageCount: 2,
    };

    it('should put and get a session', async () => {
      await db.putSession(testSession);
      const retrieved = await db.getSession(testSession.id);

      expect(retrieved).toEqual(testSession);
    });

    it('should return null for non-existent session', async () => {
      const retrieved = await db.getSession('non-existent');
      expect(retrieved).toBeNull();
    });

    it('should update existing session', async () => {
      await db.putSession(testSession);

      const updated = { ...testSession, title: 'Updated Title', eventCount: 5 };
      await db.putSession(updated);

      const retrieved = await db.getSession(testSession.id);
      expect(retrieved?.title).toBe('Updated Title');
      expect(retrieved?.eventCount).toBe(5);
    });

    it('should get all sessions ordered by lastActivityAt', async () => {
      const session1 = { ...testSession, id: 'session-1', lastActivityAt: '2024-01-01T01:00:00Z' };
      const session2 = { ...testSession, id: 'session-2', lastActivityAt: '2024-01-01T03:00:00Z' };
      const session3 = { ...testSession, id: 'session-3', lastActivityAt: '2024-01-01T02:00:00Z' };

      await db.putSession(session1);
      await db.putSession(session2);
      await db.putSession(session3);

      const sessions = await db.getAllSessions();

      expect(sessions.length).toBe(3);
      expect(sessions[0]!.id).toBe('session-2'); // Most recent first
      expect(sessions[1]!.id).toBe('session-3');
      expect(sessions[2]!.id).toBe('session-1');
    });

    it('should delete a session', async () => {
      await db.putSession(testSession);
      await db.deleteSession(testSession.id);

      const retrieved = await db.getSession(testSession.id);
      expect(retrieved).toBeNull();
    });
  });

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  describe('Event Operations', () => {
    const createEvent = (id: string, parentId: string | null, type: string, sequence: number): CachedEvent => ({
      id,
      parentId,
      sessionId: 'session-1',
      workspaceId: 'ws-1',
      type,
      timestamp: `2024-01-01T00:0${sequence}:00Z`,
      sequence,
      payload: { content: `Event ${id}` },
    });

    it('should put and get an event', async () => {
      const event = createEvent('event-1', null, 'session.start', 0);
      await db.putEvent(event);

      const retrieved = await db.getEvent('event-1');
      expect(retrieved).toEqual(event);
    });

    it('should return null for non-existent event', async () => {
      const retrieved = await db.getEvent('non-existent');
      expect(retrieved).toBeNull();
    });

    it('should put multiple events', async () => {
      const events = [
        createEvent('event-1', null, 'session.start', 0),
        createEvent('event-2', 'event-1', 'message.user', 1),
        createEvent('event-3', 'event-2', 'message.assistant', 2),
      ];

      await db.putEvents(events);

      const e1 = await db.getEvent('event-1');
      const e2 = await db.getEvent('event-2');
      const e3 = await db.getEvent('event-3');

      expect(e1).toBeTruthy();
      expect(e2).toBeTruthy();
      expect(e3).toBeTruthy();
    });

    it('should get events by session', async () => {
      const events1 = [
        createEvent('event-1', null, 'session.start', 0),
        createEvent('event-2', 'event-1', 'message.user', 1),
      ];

      const events2 = [
        { ...createEvent('event-3', null, 'session.start', 0), sessionId: 'session-2' },
      ];

      await db.putEvents(events1);
      await db.putEvents(events2);

      const session1Events = await db.getEventsBySession('session-1');
      expect(session1Events.length).toBe(2);

      const session2Events = await db.getEventsBySession('session-2');
      expect(session2Events.length).toBe(1);
    });

    it('should delete events by session', async () => {
      const events = [
        createEvent('event-1', null, 'session.start', 0),
        createEvent('event-2', 'event-1', 'message.user', 1),
      ];
      await db.putEvents(events);

      await db.deleteEventsBySession('session-1');

      const remaining = await db.getEventsBySession('session-1');
      expect(remaining.length).toBe(0);
    });
  });

  // ===========================================================================
  // Tree Navigation
  // ===========================================================================

  describe('Tree Navigation', () => {
    const createEvent = (id: string, parentId: string | null, sequence: number): CachedEvent => ({
      id,
      parentId,
      sessionId: 'session-1',
      workspaceId: 'ws-1',
      type: 'message.user',
      timestamp: `2024-01-01T00:0${sequence}:00Z`,
      sequence,
      payload: {},
    });

    it('should get ancestors (path from root to event)', async () => {
      // Create chain: 1 -> 2 -> 3 -> 4
      const events = [
        createEvent('event-1', null, 0),
        createEvent('event-2', 'event-1', 1),
        createEvent('event-3', 'event-2', 2),
        createEvent('event-4', 'event-3', 3),
      ];
      await db.putEvents(events);

      const ancestors = await db.getAncestors('event-4');

      expect(ancestors.length).toBe(4);
      expect(ancestors[0]!.id).toBe('event-1'); // Root first
      expect(ancestors[3]!.id).toBe('event-4'); // Target last
    });

    it('should get children of an event', async () => {
      // Create: 1 -> [2, 3] (2 and 3 are children of 1)
      const events = [
        createEvent('event-1', null, 0),
        createEvent('event-2', 'event-1', 1),
        createEvent('event-3', 'event-1', 2),
      ];
      await db.putEvents(events);

      const children = await db.getChildren('event-1');

      expect(children.length).toBe(2);
      expect(children.map(c => c.id).sort()).toEqual(['event-2', 'event-3']);
    });

    it('should return empty array for event with no children', async () => {
      const events = [
        createEvent('event-1', null, 0),
        createEvent('event-2', 'event-1', 1),
      ];
      await db.putEvents(events);

      const children = await db.getChildren('event-2');
      expect(children.length).toBe(0);
    });
  });

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  describe('State Reconstruction', () => {
    it('should reconstruct messages at an event', async () => {
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
      await db.putEvents(events);

      const messages = await db.getMessagesAt('event-3');

      expect(messages.length).toBe(2);
      expect(messages[0]).toEqual({ role: 'user', content: 'Hello!' });
      expect(messages[1]).toEqual({ role: 'assistant', content: 'Hi there!' });
    });

    it('should reconstruct full state at session head', async () => {
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        title: null,
        latestModel: 'claude-sonnet-4',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:02:00Z',
        endedAt: null,
        eventCount: 3,
        messageCount: 2,
      };
      await db.putSession(session);

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
          payload: { content: 'Hello!', tokenUsage: { inputTokens: 10, outputTokens: 0 } },
        },
        {
          id: 'event-3',
          parentId: 'event-2',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.assistant',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Hi!', turn: 1, tokenUsage: { inputTokens: 0, outputTokens: 20 } },
        },
      ];
      await db.putEvents(events);

      const state = await db.getStateAtHead('session-1');

      expect(state.messages.length).toBe(2);
      expect(state.tokenUsage).toEqual({ inputTokens: 10, outputTokens: 20 });
      expect(state.turnCount).toBe(1);
    });

    it('should return empty state for session without head', async () => {
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: null,
        headEventId: null,
        title: null,
        latestModel: 'claude-sonnet-4',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        endedAt: null,
        eventCount: 0,
        messageCount: 0,
      };
      await db.putSession(session);

      const state = await db.getStateAtHead('session-1');

      expect(state.messages.length).toBe(0);
      expect(state.tokenUsage).toEqual({ inputTokens: 0, outputTokens: 0 });
      expect(state.turnCount).toBe(0);
    });
  });

  // ===========================================================================
  // Tree Visualization
  // ===========================================================================

  describe('Tree Visualization', () => {
    it('should build tree visualization for linear chain', async () => {
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        title: null,
        latestModel: 'claude-sonnet-4',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        endedAt: null,
        eventCount: 3,
        messageCount: 2,
      };
      await db.putSession(session);

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
          payload: { content: 'Hello world' },
        },
        {
          id: 'event-3',
          parentId: 'event-2',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.assistant',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Response here' },
        },
      ];
      await db.putEvents(events);

      const tree = await db.buildTreeVisualization('session-1');

      expect(tree.length).toBe(3);

      // Check root
      const root = tree[0]!;
      expect(root.id).toBe('event-1');
      expect(root.depth).toBe(0);
      expect(root.hasChildren).toBe(true);
      expect(root.isHead).toBe(false);
      expect(root.summary).toBe('Session started');

      // Check head
      const head = tree.find(n => n.id === 'event-3');
      expect(head?.isHead).toBe(true);
      expect(head?.depth).toBe(2);
      expect(head?.hasChildren).toBe(false);
    });

    it('should identify branch points in tree', async () => {
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-3',
        title: null,
        latestModel: 'claude-sonnet-4',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        endedAt: null,
        eventCount: 4,
        messageCount: 3,
      };
      await db.putSession(session);

      // Create branching structure: 1 -> [2, 3] (fork point at 1)
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
          payload: { content: 'Branch A' },
        },
        {
          id: 'event-3',
          parentId: 'event-1',
          sessionId: 'session-1',
          workspaceId: 'ws-1',
          type: 'message.user',
          timestamp: '2024-01-01T00:02:00Z',
          sequence: 2,
          payload: { content: 'Branch B' },
        },
      ];
      await db.putEvents(events);

      const tree = await db.buildTreeVisualization('session-1');

      const branchPoint = tree.find(n => n.id === 'event-1');
      expect(branchPoint?.isBranchPoint).toBe(true);
      expect(branchPoint?.childCount).toBe(2);
    });
  });

  // ===========================================================================
  // Sync State
  // ===========================================================================

  describe('Sync State', () => {
    it('should put and get sync state', async () => {
      const syncState = {
        key: 'session-1',
        lastSyncedEventId: 'event-5',
        lastSyncTimestamp: '2024-01-01T00:00:00Z',
        pendingEventIds: ['event-6', 'event-7'],
      };

      await db.putSyncState(syncState);
      const retrieved = await db.getSyncState('session-1');

      expect(retrieved).toEqual(syncState);
    });

    it('should return null for non-existent sync state', async () => {
      const retrieved = await db.getSyncState('non-existent');
      expect(retrieved).toBeNull();
    });

    it('should update sync state', async () => {
      const initial = {
        key: 'session-1',
        lastSyncedEventId: 'event-5',
        lastSyncTimestamp: '2024-01-01T00:00:00Z',
        pendingEventIds: [] as string[],
      };
      await db.putSyncState(initial);

      const updated = {
        ...initial,
        lastSyncedEventId: 'event-10',
        lastSyncTimestamp: '2024-01-01T01:00:00Z',
      };
      await db.putSyncState(updated);

      const retrieved = await db.getSyncState('session-1');
      expect(retrieved?.lastSyncedEventId).toBe('event-10');
    });
  });

  // ===========================================================================
  // Utilities
  // ===========================================================================

  describe('Utilities', () => {
    it('should clear all data', async () => {
      const session: CachedSession = {
        id: 'session-1',
        workspaceId: 'ws-1',
        rootEventId: 'event-1',
        headEventId: 'event-1',
        title: null,
        latestModel: 'claude-sonnet-4',
        workingDirectory: '/test',
        createdAt: '2024-01-01T00:00:00Z',
        lastActivityAt: '2024-01-01T00:00:00Z',
        endedAt: null,
        eventCount: 1,
        messageCount: 0,
      };
      await db.putSession(session);

      const event: CachedEvent = {
        id: 'event-1',
        parentId: null,
        sessionId: 'session-1',
        workspaceId: 'ws-1',
        type: 'session.start',
        timestamp: '2024-01-01T00:00:00Z',
        sequence: 0,
        payload: {},
      };
      await db.putEvent(event);

      await db.clear();

      const sessions = await db.getAllSessions();
      const events = await db.getEventsBySession('session-1');

      expect(sessions.length).toBe(0);
      expect(events.length).toBe(0);
    });
  });
});
