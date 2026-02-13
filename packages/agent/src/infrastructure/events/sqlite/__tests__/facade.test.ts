/**
 * @fileoverview Tests for SQLite Event Store Facade
 *
 * Integration tests to verify the facade correctly wires up all repositories.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { SQLiteEventStore, createSQLiteEventStore } from '../facade.js';
import { SessionId, EventId, WorkspaceId } from '../../types.js';

describe('SQLiteEventStore Facade', () => {
  let store: SQLiteEventStore;

  beforeEach(async () => {
    store = new SQLiteEventStore(':memory:');
    await store.initialize();
  });

  afterEach(async () => {
    await store.close();
  });

  describe('lifecycle', () => {
    it('should initialize and close', async () => {
      const newStore = new SQLiteEventStore(':memory:');
      await newStore.initialize();
      expect(newStore.getDb()).toBeDefined();
      await newStore.close();
    });

    it('should handle double initialization', async () => {
      await store.initialize(); // Already initialized in beforeEach
      expect(store.getDb()).toBeDefined();
    });
  });

  describe('factory function', () => {
    it('should create initialized store', async () => {
      const factoryStore = await createSQLiteEventStore(':memory:');
      expect(factoryStore.getDb()).toBeDefined();
      await factoryStore.close();
    });
  });

  describe('workspace operations', () => {
    it('should create and retrieve workspace', async () => {
      const workspace = await store.createWorkspace({
        path: '/test/project',
        name: 'Test Project',
      });

      expect(workspace.id).toMatch(/^ws_/);
      expect(workspace.path).toBe('/test/project');
      expect(workspace.name).toBe('Test Project');

      const found = await store.getWorkspaceByPath('/test/project');
      expect(found?.id).toBe(workspace.id);
    });

    it('should get or create workspace', async () => {
      const ws1 = await store.getOrCreateWorkspace('/test', 'Test');
      const ws2 = await store.getOrCreateWorkspace('/test', 'Different Name');

      expect(ws1.id).toBe(ws2.id);
    });

    it('should list workspaces', async () => {
      await store.createWorkspace({ path: '/a' });
      await store.createWorkspace({ path: '/b' });

      const workspaces = await store.listWorkspaces();
      expect(workspaces.length).toBe(2);
    });
  });

  describe('session operations', () => {
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const ws = await store.createWorkspace({ path: '/test' });
      workspaceId = ws.id;
    });

    it('should create and retrieve session', async () => {
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        title: 'Test Session',
      });

      expect(session.id).toMatch(/^sess_/);
      expect(session.title).toBe('Test Session');

      const found = await store.getSession(session.id);
      expect(found?.id).toBe(session.id);
    });

    it('should list sessions with filters', async () => {
      await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const sessions = await store.listSessions({ workspaceId });
      expect(sessions.length).toBe(1);
    });

    it('should update session head', async () => {
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const eventId = EventId('evt_test');
      await store.updateSessionHead(session.id, eventId);

      const updated = await store.getSession(session.id);
      expect(updated?.headEventId).toBe(eventId);
    });

    it('should archive session', async () => {
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      await store.archiveSession(session.id);

      const updated = await store.getSession(session.id);
      expect(updated?.isArchived).toBe(true);
    });

    it('should increment counters', async () => {
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      await store.incrementSessionCounters(session.id, {
        eventCount: 5,
        messageCount: 2,
        inputTokens: 100,
      });

      const updated = await store.getSession(session.id);
      expect(updated?.eventCount).toBe(5);
      expect(updated?.messageCount).toBe(2);
      expect(updated?.totalInputTokens).toBe(100);
    });
  });

  describe('event operations', () => {
    let sessionId: SessionId;
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const ws = await store.createWorkspace({ path: '/test' });
      workspaceId = ws.id;
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      sessionId = session.id;
    });

    it('should insert and retrieve event', async () => {
      const event = {
        id: EventId('evt_1'),
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'Hello', turn: 0 },
      };

      await store.insertEvent(event);

      const found = await store.getEvent(event.id);
      expect(found?.id).toBe(event.id);
      expect(found?.payload).toEqual({ content: 'Hello', turn: 0 });
    });

    it('should get events by session', async () => {
      const event1 = {
        id: EventId('evt_1'),
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'First', turn: 0 },
      };
      const event2 = {
        id: EventId('evt_2'),
        sessionId,
        workspaceId,
        parentId: EventId('evt_1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: {
          content: [],
          turn: 0,
          tokenUsage: { inputTokens: 0, outputTokens: 0 },
          stopReason: 'end_turn' as const,
          model: 'claude-3',
        },
      };

      await store.insertEvent(event1);
      await store.insertEvent(event2);

      const events = await store.getEventsBySession(sessionId);
      expect(events.length).toBe(2);
    });

    it('should get ancestors', async () => {
      const event1 = {
        id: EventId('evt_1'),
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: '', turn: 0 },
      };
      const event2 = {
        id: EventId('evt_2'),
        sessionId,
        workspaceId,
        parentId: EventId('evt_1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: {
          content: [],
          turn: 0,
          tokenUsage: { inputTokens: 0, outputTokens: 0 },
          stopReason: 'end_turn' as const,
          model: 'claude-3',
        },
      };

      await store.insertEvent(event1);
      await store.insertEvent(event2);

      const ancestors = await store.getAncestors(EventId('evt_2'));
      expect(ancestors.length).toBe(2);
      expect(ancestors[0].id).toBe('evt_1');
    });

    it('should count events', async () => {
      await store.insertEvent({
        id: EventId('evt_1'),
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: '', turn: 0 },
      });

      const count = await store.countEvents(sessionId);
      expect(count).toBe(1);
    });
  });

  describe('blob operations', () => {
    it('should store and retrieve blob', async () => {
      const content = 'Hello, blob!';
      const blobId = await store.storeBlob(content);

      expect(blobId).toMatch(/^blob_/);

      const retrieved = await store.getBlob(blobId);
      expect(retrieved).toBe(content);
    });

    it('should deduplicate identical content', async () => {
      const content = 'Duplicate content';
      const blob1 = await store.storeBlob(content);
      const blob2 = await store.storeBlob(content);

      expect(blob1).toBe(blob2);
      expect(await store.getBlobRefCount(blob1)).toBe(2);
    });
  });

  describe('search operations', () => {
    let sessionId: SessionId;
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const ws = await store.createWorkspace({ path: '/test' });
      workspaceId = ws.id;
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      sessionId = session.id;
    });

    it('should index and search events', async () => {
      const event = {
        id: EventId('evt_search'),
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'searchable unique content here', turn: 0 },
      };

      await store.insertEvent(event);
      await store.indexEventForSearch(event);

      const results = await store.searchEvents('searchable');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].eventId).toBe(event.id);
    });
  });

  describe('branch operations', () => {
    let sessionId: SessionId;
    let eventId: EventId;
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const ws = await store.createWorkspace({ path: '/test' });
      workspaceId = ws.id;
      const session = await store.createSession({
        workspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      sessionId = session.id;
      eventId = EventId('evt_root');

      await store.insertEvent({
        id: eventId,
        sessionId,
        workspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: '', turn: 0 },
      });
    });

    it('should create and retrieve branch', async () => {
      const branch = await store.createBranch({
        sessionId,
        name: 'main',
        rootEventId: eventId,
        headEventId: eventId,
      });

      expect(branch.id).toMatch(/^br_/);
      expect(branch.name).toBe('main');

      const found = await store.getBranch(branch.id);
      expect(found?.id).toBe(branch.id);
    });

    it('should list branches by session', async () => {
      await store.createBranch({
        sessionId,
        name: 'branch1',
        rootEventId: eventId,
        headEventId: eventId,
      });

      const branches = await store.getBranchesBySession(sessionId);
      expect(branches.length).toBe(1);
    });
  });

  describe('stats', () => {
    it('should return database stats', async () => {
      const stats = await store.getStats();

      expect(stats).toHaveProperty('totalWorkspaces');
      expect(stats).toHaveProperty('totalSessions');
      expect(stats).toHaveProperty('totalEvents');
      expect(stats).toHaveProperty('totalBlobs');
    });
  });

  describe('schema inspection', () => {
    it('should return schema version', () => {
      const version = store.getSchemaVersion();
      expect(version).toBeGreaterThan(0);
    });

    it('should list tables', () => {
      const tables = store.listTables();
      expect(tables).toContain('workspaces');
      expect(tables).toContain('sessions');
      expect(tables).toContain('events');
      expect(tables).toContain('blobs');
    });
  });

  describe('repository access', () => {
    it('should provide direct repository access', () => {
      const repos = store.getRepositories();

      expect(repos.blob).toBeDefined();
      expect(repos.workspace).toBeDefined();
      expect(repos.branch).toBeDefined();
      expect(repos.event).toBeDefined();
      expect(repos.session).toBeDefined();
      expect(repos.search).toBeDefined();
    });
  });

  describe('transactions', () => {
    it('should support async transactions', async () => {
      const ws = await store.createWorkspace({ path: '/test' });

      await store.transactionAsync(async () => {
        await store.createSession({
          workspaceId: ws.id,
          model: 'claude-3',
          workingDirectory: '/test',
        });
        await store.createSession({
          workspaceId: ws.id,
          model: 'claude-4',
          workingDirectory: '/test',
        });
      });

      const sessions = await store.listSessions({ workspaceId: ws.id });
      expect(sessions.length).toBe(2);
    });
  });
});
