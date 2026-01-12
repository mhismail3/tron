/**
 * @fileoverview Tests for SQLite Backend
 *
 * TDD: Tests for the event store SQLite persistence layer
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { SQLiteBackend } from '../../src/events/sqlite-backend.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionStartEvent,
  type UserMessageEvent,
  type AssistantMessageEvent,
} from '../../src/events/types.js';

describe('SQLiteBackend', () => {
  let backend: SQLiteBackend;

  beforeEach(async () => {
    // Use in-memory database for tests
    backend = new SQLiteBackend(':memory:');
    await backend.initialize();
  });

  afterEach(async () => {
    await backend.close();
  });

  describe('initialization', () => {
    it('should initialize with in-memory database', async () => {
      expect(backend.isInitialized()).toBe(true);
    });

    it('should be idempotent on multiple initialize calls', async () => {
      await backend.initialize();
      await backend.initialize();
      expect(backend.isInitialized()).toBe(true);
    });

    it('should create all required tables', async () => {
      const tables = backend.listTables();
      expect(tables).toContain('workspaces');
      expect(tables).toContain('sessions');
      expect(tables).toContain('events');
      expect(tables).toContain('blobs');
      expect(tables).toContain('branches');
      expect(tables).toContain('schema_version');
    });

    it('should create FTS5 virtual table', async () => {
      const tables = backend.listTables();
      expect(tables).toContain('events_fts');
    });

    it('should record schema version', async () => {
      const version = backend.getSchemaVersion();
      expect(version).toBe(2);  // Updated: migration 002 for schema cleanup
    });
  });

  describe('workspace operations', () => {
    it('should create a workspace', async () => {
      const workspace = await backend.createWorkspace({
        path: '/home/user/project',
        name: 'My Project',
      });

      expect(workspace.id).toMatch(/^ws_/);
      expect(workspace.path).toBe('/home/user/project');
      expect(workspace.name).toBe('My Project');
    });

    it('should get workspace by path', async () => {
      await backend.createWorkspace({ path: '/home/user/project' });

      const workspace = await backend.getWorkspaceByPath('/home/user/project');

      expect(workspace).not.toBeNull();
      expect(workspace?.path).toBe('/home/user/project');
    });

    it('should return null for non-existent workspace', async () => {
      const workspace = await backend.getWorkspaceByPath('/nonexistent');
      expect(workspace).toBeNull();
    });

    it('should get or create workspace', async () => {
      const ws1 = await backend.getOrCreateWorkspace('/home/user/project');
      const ws2 = await backend.getOrCreateWorkspace('/home/user/project');

      expect(ws1.id).toBe(ws2.id);
    });

    it('should list workspaces', async () => {
      await backend.createWorkspace({ path: '/project1' });
      await backend.createWorkspace({ path: '/project2' });

      const workspaces = await backend.listWorkspaces();

      expect(workspaces.length).toBe(2);
    });
  });

  describe('session operations', () => {
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const workspace = await backend.createWorkspace({ path: '/test' });
      workspaceId = workspace.id;
    });

    it('should create a session', async () => {
      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      expect(session.id).toMatch(/^sess_/);
      expect(session.workspaceId).toBe(workspaceId);
      expect(session.model).toBe('claude-sonnet-4-20250514');
      expect(session.isEnded).toBe(false);
    });

    it('should get session by id', async () => {
      const created = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      const session = await backend.getSession(created.id);

      expect(session).not.toBeNull();
      expect(session?.id).toBe(created.id);
    });

    it('should return null for non-existent session', async () => {
      const session = await backend.getSession(SessionId('sess_nonexistent'));
      expect(session).toBeNull();
    });

    it('should list sessions by workspace', async () => {
      await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });
      await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      const sessions = await backend.listSessions({ workspaceId });

      expect(sessions.length).toBe(2);
    });

    it('should update session head', async () => {
      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      const eventId = EventId('evt_test123');
      await backend.updateSessionHead(session.id, eventId);

      const updated = await backend.getSession(session.id);
      expect(updated?.headEventId).toBe(eventId);
    });

    it('should mark session as ended', async () => {
      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      await backend.markSessionEnded(session.id);

      const updated = await backend.getSession(session.id);
      expect(updated?.isEnded).toBe(true);
    });

    it('should increment session counters', async () => {
      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      await backend.incrementSessionCounters(session.id, {
        eventCount: 1,
        messageCount: 1,
        inputTokens: 100,
        outputTokens: 50,
      });

      const updated = await backend.getSession(session.id);
      expect(updated?.eventCount).toBe(1);
      expect(updated?.messageCount).toBe(1);
      expect(updated?.totalInputTokens).toBe(100);
      expect(updated?.totalOutputTokens).toBe(50);
    });
  });

  describe('event operations', () => {
    let workspaceId: WorkspaceId;
    let sessionId: SessionId;

    beforeEach(async () => {
      const workspace = await backend.createWorkspace({ path: '/test' });
      workspaceId = workspace.id;

      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = session.id;
    });

    it('should insert an event', async () => {
      const event: SessionStartEvent = {
        id: EventId('evt_test123'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: {
          workingDirectory: '/test',
          model: 'claude-sonnet-4-20250514',
          },
      };

      await backend.insertEvent(event);

      const retrieved = await backend.getEvent(event.id);
      expect(retrieved).not.toBeNull();
      expect(retrieved?.type).toBe('session.start');
    });

    it('should get event by id', async () => {
      const event: SessionStartEvent = {
        id: EventId('evt_test456'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: {
          workingDirectory: '/test',
          model: 'claude-sonnet-4-20250514',
          },
      };

      await backend.insertEvent(event);

      const retrieved = await backend.getEvent(event.id);
      expect(retrieved?.id).toBe(event.id);
      expect(retrieved?.payload).toEqual(event.payload);
    });

    it('should return null for non-existent event', async () => {
      const event = await backend.getEvent(EventId('evt_nonexistent'));
      expect(event).toBeNull();
    });

    it('should get multiple events by ids', async () => {
      const event1: SessionStartEvent = {
        id: EventId('evt_1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      const event2: UserMessageEvent = {
        id: EventId('evt_2'),
        parentId: EventId('evt_1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      await backend.insertEvent(event1);
      await backend.insertEvent(event2);

      const events = await backend.getEvents([EventId('evt_1'), EventId('evt_2')]);

      expect(events.size).toBe(2);
      expect(events.get(EventId('evt_1'))?.type).toBe('session.start');
      expect(events.get(EventId('evt_2'))?.type).toBe('message.user');
    });

    it('should get events by session', async () => {
      const event1: SessionStartEvent = {
        id: EventId('evt_s1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      const event2: UserMessageEvent = {
        id: EventId('evt_s2'),
        parentId: EventId('evt_s1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      await backend.insertEvent(event1);
      await backend.insertEvent(event2);

      const events = await backend.getEventsBySession(sessionId);

      expect(events.length).toBe(2);
      expect(events[0].sequence).toBeLessThan(events[1].sequence);
    });

    it('should get events by type', async () => {
      const startEvent: SessionStartEvent = {
        id: EventId('evt_t1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      const userEvent: UserMessageEvent = {
        id: EventId('evt_t2'),
        parentId: EventId('evt_t1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      await backend.insertEvent(startEvent);
      await backend.insertEvent(userEvent);

      const messages = await backend.getEventsByType(sessionId, ['message.user']);

      expect(messages.length).toBe(1);
      expect(messages[0].type).toBe('message.user');
    });

    it('should get next sequence number', async () => {
      const event: SessionStartEvent = {
        id: EventId('evt_seq1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      await backend.insertEvent(event);

      const nextSeq = await backend.getNextSequence(sessionId);
      expect(nextSeq).toBe(1);
    });

    it('should get ancestors of an event', async () => {
      const event1: SessionStartEvent = {
        id: EventId('evt_a1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      const event2: UserMessageEvent = {
        id: EventId('evt_a2'),
        parentId: EventId('evt_a1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      const event3: AssistantMessageEvent = {
        id: EventId('evt_a3'),
        parentId: EventId('evt_a2'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.assistant',
        sequence: 2,
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      };

      await backend.insertEvent(event1);
      await backend.insertEvent(event2);
      await backend.insertEvent(event3);

      const ancestors = await backend.getAncestors(EventId('evt_a3'));

      expect(ancestors.length).toBe(3); // Includes self
      expect(ancestors[0].id).toBe('evt_a1'); // Root first
      expect(ancestors[2].id).toBe('evt_a3'); // Self last
    });

    it('should get children of an event', async () => {
      const root: SessionStartEvent = {
        id: EventId('evt_c1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      const child1: UserMessageEvent = {
        id: EventId('evt_c2'),
        parentId: EventId('evt_c1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      const child2: UserMessageEvent = {
        id: EventId('evt_c3'),
        parentId: EventId('evt_c1'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 2,
        payload: { content: 'Also hello', turn: 2 },
      };

      await backend.insertEvent(root);
      await backend.insertEvent(child1);
      await backend.insertEvent(child2);

      const children = await backend.getChildren(EventId('evt_c1'));

      expect(children.length).toBe(2);
    });

    it('should count events in session', async () => {
      const event: SessionStartEvent = {
        id: EventId('evt_count1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      await backend.insertEvent(event);

      const count = await backend.countEvents(sessionId);
      expect(count).toBe(1);
    });
  });

  describe('blob operations', () => {
    it('should store a blob', async () => {
      const content = 'This is a large piece of content';
      const blobId = await backend.storeBlob(content);

      expect(blobId).toMatch(/^blob_/);
    });

    it('should retrieve a blob', async () => {
      const content = 'This is a large piece of content';
      const blobId = await backend.storeBlob(content);

      const retrieved = await backend.getBlob(blobId);

      expect(retrieved).toBe(content);
    });

    it('should deduplicate identical content', async () => {
      const content = 'Duplicate content';
      const blobId1 = await backend.storeBlob(content);
      const blobId2 = await backend.storeBlob(content);

      expect(blobId1).toBe(blobId2);
    });

    it('should increment ref count on duplicate', async () => {
      const content = 'Content with refs';
      const blobId = await backend.storeBlob(content);
      await backend.storeBlob(content);

      const refCount = await backend.getBlobRefCount(blobId);
      expect(refCount).toBe(2);
    });

    it('should return null for non-existent blob', async () => {
      const blob = await backend.getBlob('blob_nonexistent');
      expect(blob).toBeNull();
    });
  });

  describe('FTS5 search', () => {
    let workspaceId: WorkspaceId;
    let sessionId: SessionId;

    beforeEach(async () => {
      const workspace = await backend.createWorkspace({ path: '/test' });
      workspaceId = workspace.id;

      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = session.id;
    });

    it('should index events for search', async () => {
      const event: UserMessageEvent = {
        id: EventId('evt_search1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 0,
        payload: { content: 'How do I implement authentication?', turn: 1 },
      };

      await backend.insertEvent(event);
      await backend.indexEventForSearch(event);

      const results = await backend.searchEvents('authentication');

      expect(results.length).toBe(1);
      expect(results[0].eventId).toBe('evt_search1');
    });

    it('should search across multiple events', async () => {
      const event1: UserMessageEvent = {
        id: EventId('evt_search2'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 0,
        payload: { content: 'Help with OAuth implementation', turn: 1 },
      };

      const event2: AssistantMessageEvent = {
        id: EventId('evt_search3'),
        parentId: EventId('evt_search2'),
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.assistant',
        sequence: 1,
        payload: {
          content: [{ type: 'text', text: 'Here is how to implement OAuth authentication' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 50 },
          stopReason: 'end_turn',
          model: 'test',
        },
      };

      await backend.insertEvent(event1);
      await backend.insertEvent(event2);
      await backend.indexEventForSearch(event1);
      await backend.indexEventForSearch(event2);

      const results = await backend.searchEvents('OAuth');

      expect(results.length).toBe(2);
    });

    it('should filter search by workspace', async () => {
      const workspace2 = await backend.createWorkspace({ path: '/other' });
      const session2 = await backend.createSession({
        workspaceId: workspace2.id,
        workingDirectory: '/other',
        model: 'test',
        provider: 'test',
      });

      const event1: UserMessageEvent = {
        id: EventId('evt_ws1'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 0,
        payload: { content: 'Database queries here', turn: 1 },
      };

      const event2: UserMessageEvent = {
        id: EventId('evt_ws2'),
        parentId: null,
        sessionId: session2.id,
        workspaceId: workspace2.id,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 0,
        payload: { content: 'Database queries there', turn: 1 },
      };

      await backend.insertEvent(event1);
      await backend.insertEvent(event2);
      await backend.indexEventForSearch(event1);
      await backend.indexEventForSearch(event2);

      const results = await backend.searchEvents('database', { workspaceId });

      expect(results.length).toBe(1);
      expect(results[0].eventId).toBe('evt_ws1');
    });

    it('should return empty array for no matches', async () => {
      const results = await backend.searchEvents('xyznonexistent');
      expect(results).toEqual([]);
    });
  });

  describe('branch operations', () => {
    let workspaceId: WorkspaceId;
    let sessionId: SessionId;
    let rootEventId: EventId;

    beforeEach(async () => {
      const workspace = await backend.createWorkspace({ path: '/test' });
      workspaceId = workspace.id;

      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = session.id;

      const rootEvent: SessionStartEvent = {
        id: EventId('evt_branch_root'),
        parentId: null,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.start',
        sequence: 0,
        payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
      };

      await backend.insertEvent(rootEvent);
      rootEventId = rootEvent.id;
    });

    it('should create a branch', async () => {
      const branch = await backend.createBranch({
        sessionId,
        name: 'Main Branch',
        rootEventId,
        headEventId: rootEventId,
        isDefault: true,
      });

      expect(branch.id).toMatch(/^br_/);
      expect(branch.name).toBe('Main Branch');
      expect(branch.isDefault).toBe(true);
    });

    it('should get branches by session', async () => {
      await backend.createBranch({
        sessionId,
        name: 'Branch 1',
        rootEventId,
        headEventId: rootEventId,
        isDefault: true,
      });

      await backend.createBranch({
        sessionId,
        name: 'Branch 2',
        rootEventId,
        headEventId: rootEventId,
        isDefault: false,
      });

      const branches = await backend.getBranchesBySession(sessionId);

      expect(branches.length).toBe(2);
    });

    it('should update branch head', async () => {
      const branch = await backend.createBranch({
        sessionId,
        name: 'Test Branch',
        rootEventId,
        headEventId: rootEventId,
        isDefault: true,
      });

      const newEvent: UserMessageEvent = {
        id: EventId('evt_branch_new'),
        parentId: rootEventId,
        sessionId,
        workspaceId,
        timestamp: new Date().toISOString(),
        type: 'message.user',
        sequence: 1,
        payload: { content: 'Hello', turn: 1 },
      };

      await backend.insertEvent(newEvent);
      await backend.updateBranchHead(branch.id, newEvent.id);

      const updated = await backend.getBranch(branch.id);
      expect(updated?.headEventId).toBe(newEvent.id);
    });
  });

  describe('transaction support', () => {
    let workspaceId: WorkspaceId;
    let sessionId: SessionId;

    beforeEach(async () => {
      const workspace = await backend.createWorkspace({ path: '/test' });
      workspaceId = workspace.id;

      const session = await backend.createSession({
        workspaceId,
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = session.id;
    });

    it('should support transactions', async () => {
      await backend.transactionAsync(async () => {
        const event: SessionStartEvent = {
          id: EventId('evt_tx1'),
          parentId: null,
          sessionId,
          workspaceId,
          timestamp: new Date().toISOString(),
          type: 'session.start',
          sequence: 0,
          payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
        };

        await backend.insertEvent(event);
      });

      const event = await backend.getEvent(EventId('evt_tx1'));
      expect(event).not.toBeNull();
    });

    it('should rollback on error', async () => {
      try {
        await backend.transactionAsync(async () => {
          const event: SessionStartEvent = {
            id: EventId('evt_tx_fail'),
            parentId: null,
            sessionId,
            workspaceId,
            timestamp: new Date().toISOString(),
            type: 'session.start',
            sequence: 0,
            payload: { workingDirectory: '/test', model: 'test', provider: 'test' },
          };

          await backend.insertEvent(event);
          throw new Error('Intentional error');
        });
      } catch {
        // Expected
      }

      const event = await backend.getEvent(EventId('evt_tx_fail'));
      expect(event).toBeNull();
    });
  });

  describe('statistics', () => {
    it('should return database stats', async () => {
      const stats = await backend.getStats();

      expect(stats).toHaveProperty('totalEvents');
      expect(stats).toHaveProperty('totalSessions');
      expect(stats).toHaveProperty('totalWorkspaces');
      expect(typeof stats.totalEvents).toBe('number');
    });
  });
});
