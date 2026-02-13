/**
 * @fileoverview Tests for Session Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { SessionRepository } from '../../repositories/session.repo.js';
import { SessionId, EventId, WorkspaceId } from '../../../types.js';

describe('SessionRepository', () => {
  let connection: DatabaseConnection;
  let repo: SessionRepository;
  let testWorkspaceId: WorkspaceId;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new SessionRepository(connection);

    // Create test workspace
    testWorkspaceId = WorkspaceId('ws_test');
    db.prepare(`
      INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `).run(testWorkspaceId, '/test', 'Test');
  });

  afterEach(() => {
    connection.close();
  });

  describe('create', () => {
    it('should create a session', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test/dir',
      });

      expect(session.id).toMatch(/^sess_[a-f0-9]+$/);
      expect(session.workspaceId).toBe(testWorkspaceId);
      expect(session.latestModel).toBe('claude-3');
      expect(session.model).toBe('claude-3'); // alias
      expect(session.workingDirectory).toBe('/test/dir');
      expect(session.headEventId).toBeNull();
      expect(session.rootEventId).toBeNull();
      expect(session.isArchived).toBe(false);
    });

    it('should create session with title', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        title: 'My Session',
      });

      expect(session.title).toBe('My Session');
    });

    it('should create session with tags', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        tags: ['debug', 'feature'],
      });

      expect(session.tags).toEqual(['debug', 'feature']);
    });

    it('should create forked session', () => {
      const parentSession = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      const forkEventId = EventId('evt_fork');

      const forked = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        parentSessionId: parentSession.id,
        forkFromEventId: forkEventId,
      });

      expect(forked.parentSessionId).toBe(parentSession.id);
      expect(forked.forkFromEventId).toBe(forkEventId);
    });

    it('should initialize counters to zero', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      expect(session.eventCount).toBe(0);
      expect(session.messageCount).toBe(0);
      expect(session.turnCount).toBe(0);
      expect(session.totalInputTokens).toBe(0);
      expect(session.totalOutputTokens).toBe(0);
      expect(session.lastTurnInputTokens).toBe(0);
      expect(session.totalCost).toBe(0);
      expect(session.totalCacheReadTokens).toBe(0);
      expect(session.totalCacheCreationTokens).toBe(0);
    });
  });

  describe('getById', () => {
    it('should return null for non-existent session', () => {
      const session = repo.getById(SessionId('sess_nonexistent'));
      expect(session).toBeNull();
    });

    it('should return session by ID', () => {
      const created = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const found = repo.getById(created.id);
      expect(found).not.toBeNull();
      expect(found?.id).toBe(created.id);
    });
  });

  describe('getByIds', () => {
    it('should return empty map for empty array', () => {
      const result = repo.getByIds([]);
      expect(result.size).toBe(0);
    });

    it('should return map of found sessions', () => {
      const s1 = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      const s2 = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const result = repo.getByIds([s1.id, s2.id, SessionId('sess_nonexistent')]);

      expect(result.size).toBe(2);
      expect(result.get(s1.id)?.id).toBe(s1.id);
      expect(result.get(s2.id)?.id).toBe(s2.id);
    });
  });

  describe('list', () => {
    it('should return empty array when no sessions', () => {
      const sessions = repo.list();
      expect(sessions).toEqual([]);
    });

    it('should filter by workspace', () => {
      const ws2 = WorkspaceId('ws_other');
      const db = connection.getDatabase();
      db.prepare(`
        INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
        VALUES (?, ?, ?, datetime('now'), datetime('now'))
      `).run(ws2, '/other', 'Other');

      repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.create({
        workspaceId: ws2,
        model: 'claude-3',
        workingDirectory: '/other',
      });

      const sessions = repo.list({ workspaceId: testWorkspaceId });
      expect(sessions).toHaveLength(1);
      expect(sessions[0].workspaceId).toBe(testWorkspaceId);
    });

    it('should filter by archived state', () => {
      const active = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      const archived = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.archive(archived.id);

      const activeSessions = repo.list({ archived: false });
      expect(activeSessions).toHaveLength(1);
      expect(activeSessions[0].id).toBe(active.id);

      const archivedSessions = repo.list({ archived: true });
      expect(archivedSessions).toHaveLength(1);
      expect(archivedSessions[0].id).toBe(archived.id);
    });

    it('should order by createdAt', async () => {
      const s1 = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      await new Promise(resolve => setTimeout(resolve, 10));
      const s2 = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const asc = repo.list({ orderBy: 'createdAt', order: 'asc' });
      expect(asc[0].id).toBe(s1.id);
      expect(asc[1].id).toBe(s2.id);

      const desc = repo.list({ orderBy: 'createdAt', order: 'desc' });
      expect(desc[0].id).toBe(s2.id);
      expect(desc[1].id).toBe(s1.id);
    });

    it('should respect limit and offset', () => {
      for (let i = 0; i < 5; i++) {
        repo.create({
          workspaceId: testWorkspaceId,
          model: 'claude-3',
          workingDirectory: '/test',
        });
      }

      const page1 = repo.list({ limit: 2, orderBy: 'createdAt', order: 'asc' });
      expect(page1).toHaveLength(2);

      const page2 = repo.list({ limit: 2, offset: 2, orderBy: 'createdAt', order: 'asc' });
      expect(page2).toHaveLength(2);
      expect(page2[0].id).not.toBe(page1[0].id);
    });
  });

  describe('getMessagePreviews', () => {
    it('should return empty map for empty array', () => {
      const result = repo.getMessagePreviews([]);
      expect(result.size).toBe(0);
    });

    it('should return empty previews for sessions without messages', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const result = repo.getMessagePreviews([session.id]);
      expect(result.get(session.id)).toEqual({});
    });

    it('should extract last user and assistant messages', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const db = connection.getDatabase();
      // Insert user message
      db.prepare(`
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
        VALUES (?, ?, ?, ?, datetime('now'), ?, ?)
      `).run(
        'evt_1',
        session.id,
        0,
        'message.user',
        JSON.stringify({ content: 'Hello user' }),
        testWorkspaceId
      );
      // Insert assistant message
      db.prepare(`
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
        VALUES (?, ?, ?, ?, datetime('now'), ?, ?)
      `).run(
        'evt_2',
        session.id,
        1,
        'message.assistant',
        JSON.stringify({ content: 'Hello assistant' }),
        testWorkspaceId
      );

      const result = repo.getMessagePreviews([session.id]);
      const preview = result.get(session.id);
      expect(preview?.lastUserPrompt).toBe('Hello user');
      expect(preview?.lastAssistantResponse).toBe('Hello assistant');
    });

    it('should extract text from block array content', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const db = connection.getDatabase();
      db.prepare(`
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
        VALUES (?, ?, ?, ?, datetime('now'), ?, ?)
      `).run(
        'evt_1',
        session.id,
        0,
        'message.user',
        JSON.stringify({
          content: [
            { type: 'text', text: 'First ' },
            { type: 'text', text: 'Second' },
          ],
        }),
        testWorkspaceId
      );

      const result = repo.getMessagePreviews([session.id]);
      expect(result.get(session.id)?.lastUserPrompt).toBe('First Second');
    });
  });

  describe('updateHead', () => {
    it('should update head event', async () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const eventId = EventId('evt_head');
      await new Promise(resolve => setTimeout(resolve, 10));
      repo.updateHead(session.id, eventId);

      const updated = repo.getById(session.id);
      expect(updated?.headEventId).toBe(eventId);
      expect(updated?.lastActivityAt).not.toBe(session.lastActivityAt);
    });
  });

  describe('updateRoot', () => {
    it('should update root event', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const eventId = EventId('evt_root');
      repo.updateRoot(session.id, eventId);

      const updated = repo.getById(session.id);
      expect(updated?.rootEventId).toBe(eventId);
    });
  });

  describe('archive / unarchive', () => {
    it('should archive session', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      repo.archive(session.id);

      const updated = repo.getById(session.id);
      expect(updated?.archivedAt).not.toBeNull();
      expect(updated?.isArchived).toBe(true);
    });

    it('should unarchive session', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.archive(session.id);

      repo.unarchive(session.id);

      const updated = repo.getById(session.id);
      expect(updated?.archivedAt).toBeNull();
      expect(updated?.isArchived).toBe(false);
    });
  });

  describe('updateLatestModel', () => {
    it('should update model', async () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      await new Promise(resolve => setTimeout(resolve, 10));
      repo.updateLatestModel(session.id, 'claude-4');

      const updated = repo.getById(session.id);
      expect(updated?.latestModel).toBe('claude-4');
      expect(updated?.model).toBe('claude-4'); // alias
    });
  });

  describe('updateTitle', () => {
    it('should update title', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      repo.updateTitle(session.id, 'New Title');

      const updated = repo.getById(session.id);
      expect(updated?.title).toBe('New Title');
    });

    it('should clear title with null', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        title: 'Old Title',
      });

      repo.updateTitle(session.id, null);

      const updated = repo.getById(session.id);
      expect(updated?.title).toBeNull();
    });
  });

  describe('updateTags', () => {
    it('should update tags', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
        tags: ['old'],
      });

      repo.updateTags(session.id, ['new', 'tags']);

      const updated = repo.getById(session.id);
      expect(updated?.tags).toEqual(['new', 'tags']);
    });
  });

  describe('incrementCounters', () => {
    it('should increment event count', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      repo.incrementCounters(session.id, { eventCount: 5 });
      repo.incrementCounters(session.id, { eventCount: 3 });

      const updated = repo.getById(session.id);
      expect(updated?.eventCount).toBe(8);
    });

    it('should increment multiple counters', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      repo.incrementCounters(session.id, {
        eventCount: 1,
        messageCount: 2,
        turnCount: 1,
        inputTokens: 100,
        outputTokens: 50,
        cost: 0.01,
        cacheReadTokens: 20,
        cacheCreationTokens: 10,
      });

      const updated = repo.getById(session.id);
      expect(updated?.eventCount).toBe(1);
      expect(updated?.messageCount).toBe(2);
      expect(updated?.turnCount).toBe(1);
      expect(updated?.totalInputTokens).toBe(100);
      expect(updated?.totalOutputTokens).toBe(50);
      expect(updated?.totalCost).toBe(0.01);
      expect(updated?.totalCacheReadTokens).toBe(20);
      expect(updated?.totalCacheCreationTokens).toBe(10);
    });

    it('should SET lastTurnInputTokens (not increment)', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      repo.incrementCounters(session.id, { lastTurnInputTokens: 100 });
      repo.incrementCounters(session.id, { lastTurnInputTokens: 50 });

      const updated = repo.getById(session.id);
      expect(updated?.lastTurnInputTokens).toBe(50); // SET, not incremented
    });

    it('should do nothing for empty counters', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const originalActivity = session.lastActivityAt;
      repo.incrementCounters(session.id, {});

      const updated = repo.getById(session.id);
      expect(updated?.lastActivityAt).toBe(originalActivity);
    });
  });

  describe('countByWorkspace', () => {
    it('should return 0 for empty workspace', () => {
      expect(repo.countByWorkspace(testWorkspaceId)).toBe(0);
    });

    it('should count sessions', () => {
      repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      expect(repo.countByWorkspace(testWorkspaceId)).toBe(2);
    });
  });

  describe('countByWorkspace (excluding archived)', () => {
    it('should only count non-archived sessions', () => {
      const active = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      const archived = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.archive(archived.id);

      expect(repo.countByWorkspace(testWorkspaceId)).toBe(1);
    });
  });

  describe('exists', () => {
    it('should return false for non-existent session', () => {
      expect(repo.exists(SessionId('sess_nonexistent'))).toBe(false);
    });

    it('should return true for existing session', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      expect(repo.exists(session.id)).toBe(true);
    });
  });

  describe('delete', () => {
    it('should delete session', () => {
      const session = repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const deleted = repo.delete(session.id);
      expect(deleted).toBe(true);
      expect(repo.getById(session.id)).toBeNull();
    });

    it('should return false for non-existent session', () => {
      const deleted = repo.delete(SessionId('sess_nonexistent'));
      expect(deleted).toBe(false);
    });
  });

  describe('deleteByWorkspace', () => {
    it('should delete all sessions for workspace', () => {
      repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });
      repo.create({
        workspaceId: testWorkspaceId,
        model: 'claude-3',
        workingDirectory: '/test',
      });

      const deleted = repo.deleteByWorkspace(testWorkspaceId);
      expect(deleted).toBe(2);
      expect(repo.countByWorkspace(testWorkspaceId)).toBe(0);
    });
  });
});
