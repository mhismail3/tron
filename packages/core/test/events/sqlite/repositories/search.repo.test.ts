/**
 * @fileoverview Tests for Search Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../../../src/events/sqlite/database.js';
import { runMigrations } from '../../../../src/events/sqlite/migrations/index.js';
import { SearchRepository } from '../../../../src/events/sqlite/repositories/search.repo.js';
import { EventRepository } from '../../../../src/events/sqlite/repositories/event.repo.js';
import { SessionId, EventId, WorkspaceId } from '../../../../src/events/types.js';

describe('SearchRepository', () => {
  let connection: DatabaseConnection;
  let searchRepo: SearchRepository;
  let eventRepo: EventRepository;
  let testSessionId: SessionId;
  let testWorkspaceId: WorkspaceId;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    searchRepo = new SearchRepository(connection);
    eventRepo = new EventRepository(connection);

    // Create test workspace
    testWorkspaceId = WorkspaceId('ws_test');
    db.prepare(`
      INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `).run(testWorkspaceId, '/test', 'Test');

    // Create test session
    testSessionId = SessionId('sess_test');
    db.prepare(`
      INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
      VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
    `).run(testSessionId, testWorkspaceId, 'test-model', '/test');
  });

  afterEach(() => {
    connection.close();
  });

  describe('index', () => {
    it('should index an event with string content', async () => {
      const eventId = EventId('evt_1');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'Hello world this is a test message' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      expect(searchRepo.isIndexed(eventId)).toBe(true);
    });

    it('should index an event with block array content', async () => {
      const eventId = EventId('evt_2');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: {
          content: [
            { type: 'text', text: 'First block ' },
            { type: 'text', text: 'Second block' },
          ],
        },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      expect(searchRepo.isIndexed(eventId)).toBe(true);
    });

    it('should index tool name', async () => {
      const eventId = EventId('evt_3');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'tool.call' as const,
        sequence: 2,
        timestamp: new Date().toISOString(),
        payload: { toolName: 'bash', content: 'ls -la' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      const results = searchRepo.searchByToolName('bash');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].eventId).toBe(eventId);
    });
  });

  describe('indexBatch', () => {
    it('should index multiple events', async () => {
      const events = [
        {
          id: EventId('evt_batch_1'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: null,
          type: 'message.user' as const,
          sequence: 0,
          timestamp: new Date().toISOString(),
          payload: { content: 'First message' },
        },
        {
          id: EventId('evt_batch_2'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_batch_1'),
          type: 'message.assistant' as const,
          sequence: 1,
          timestamp: new Date().toISOString(),
          payload: { content: 'Second message' },
        },
      ];

      // FTS triggers auto-index on insert
      await eventRepo.insertBatch(events);

      expect(searchRepo.countBySession(testSessionId)).toBe(2);
    });

    it('should handle empty array', () => {
      searchRepo.indexBatch([]);
      expect(searchRepo.countBySession(testSessionId)).toBe(0);
    });
  });

  describe('search', () => {
    beforeEach(async () => {
      const events = [
        {
          id: EventId('evt_s1'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: null,
          type: 'message.user' as const,
          sequence: 0,
          timestamp: new Date().toISOString(),
          payload: { content: 'Hello world test query' },
        },
        {
          id: EventId('evt_s2'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_s1'),
          type: 'message.assistant' as const,
          sequence: 1,
          timestamp: new Date().toISOString(),
          payload: { content: 'Response with different content' },
        },
        {
          id: EventId('evt_s3'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_s2'),
          type: 'tool.call' as const,
          sequence: 2,
          timestamp: new Date().toISOString(),
          payload: { toolName: 'read', content: 'Reading file test' },
        },
      ];

      await eventRepo.insertBatch(events);
      searchRepo.indexBatch(events);
    });

    it('should find events matching query', () => {
      const results = searchRepo.search('test');
      expect(results.length).toBeGreaterThan(0);
    });

    it('should return snippet with match highlighting', () => {
      const results = searchRepo.search('hello');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].snippet).toContain('<mark>');
    });

    it('should return score for ranking', () => {
      const results = searchRepo.search('test');
      expect(results[0].score).toBeGreaterThan(0);
    });

    it('should filter by session', () => {
      const otherSession = SessionId('sess_other');
      const db = connection.getDatabase();
      db.prepare(`
        INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
        VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
      `).run(otherSession, testWorkspaceId, 'test-model', '/test');

      const results = searchRepo.search('test', { sessionId: testSessionId });
      for (const result of results) {
        expect(result.sessionId).toBe(testSessionId);
      }
    });

    it('should filter by types', () => {
      const results = searchRepo.search('test', { types: ['message.user'] });
      for (const result of results) {
        expect(result.type).toBe('message.user');
      }
    });

    it('should respect limit', () => {
      const results = searchRepo.search('test', { limit: 1 });
      expect(results.length).toBeLessThanOrEqual(1);
    });

    it('should return empty array for no matches', () => {
      const results = searchRepo.search('nonexistentquery12345');
      expect(results).toEqual([]);
    });
  });

  describe('searchInSession', () => {
    it('should search within specific session', async () => {
      const event = {
        id: EventId('evt_in_session'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'unique search term here' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      const results = searchRepo.searchInSession(testSessionId, 'unique');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].sessionId).toBe(testSessionId);
    });
  });

  describe('searchInWorkspace', () => {
    it('should search within specific workspace', async () => {
      const event = {
        id: EventId('evt_in_workspace'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'workspace specific term' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      const results = searchRepo.searchInWorkspace(testWorkspaceId, 'workspace');
      expect(results.length).toBeGreaterThan(0);
    });
  });

  describe('searchByToolName', () => {
    it('should find events by tool name', async () => {
      const event = {
        id: EventId('evt_tool'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'tool.call' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { toolName: 'grep', content: 'searching for pattern' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      const results = searchRepo.searchByToolName('grep');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].eventId).toBe(event.id);
    });
  });

  describe('remove', () => {
    it('should remove event from index', async () => {
      const eventId = EventId('evt_remove');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'to be removed' },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);
      expect(searchRepo.isIndexed(eventId)).toBe(true);

      const removed = searchRepo.remove(eventId);
      expect(removed).toBe(true);
      expect(searchRepo.isIndexed(eventId)).toBe(false);
    });

    it('should return false for non-indexed event', () => {
      const removed = searchRepo.remove(EventId('evt_nonexistent'));
      expect(removed).toBe(false);
    });
  });

  describe('removeBySession', () => {
    it('should remove all events for session', async () => {
      const events = [
        {
          id: EventId('evt_rs1'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: null,
          type: 'message.user' as const,
          sequence: 0,
          timestamp: new Date().toISOString(),
          payload: { content: 'message 1' },
        },
        {
          id: EventId('evt_rs2'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_rs1'),
          type: 'message.assistant' as const,
          sequence: 1,
          timestamp: new Date().toISOString(),
          payload: { content: 'message 2' },
        },
      ];

      // FTS triggers auto-index on insert
      await eventRepo.insertBatch(events);
      expect(searchRepo.countBySession(testSessionId)).toBe(2);

      const removed = searchRepo.removeBySession(testSessionId);
      expect(removed).toBe(2);
      expect(searchRepo.countBySession(testSessionId)).toBe(0);
    });
  });

  describe('isIndexed', () => {
    it('should return false for non-indexed event', () => {
      expect(searchRepo.isIndexed(EventId('evt_not_indexed'))).toBe(false);
    });

    it('should return true for indexed event', async () => {
      const eventId = EventId('evt_indexed');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'indexed content' },
      };

      // FTS triggers auto-index on insert
      await eventRepo.insert(event);

      expect(searchRepo.isIndexed(eventId)).toBe(true);
    });
  });

  describe('countBySession', () => {
    it('should return 0 for empty session', () => {
      expect(searchRepo.countBySession(testSessionId)).toBe(0);
    });

    it('should return count of indexed events', async () => {
      const events = [
        {
          id: EventId('evt_c1'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: null,
          type: 'message.user' as const,
          sequence: 0,
          timestamp: new Date().toISOString(),
          payload: { content: 'count 1' },
        },
        {
          id: EventId('evt_c2'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_c1'),
          type: 'message.assistant' as const,
          sequence: 1,
          timestamp: new Date().toISOString(),
          payload: { content: 'count 2' },
        },
      ];

      // FTS triggers auto-index on insert
      await eventRepo.insertBatch(events);

      expect(searchRepo.countBySession(testSessionId)).toBe(2);
    });
  });

  describe('rebuildSessionIndex', () => {
    it('should rebuild index from events table', async () => {
      const events = [
        {
          id: EventId('evt_rb1'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: null,
          type: 'message.user' as const,
          sequence: 0,
          timestamp: new Date().toISOString(),
          payload: { content: 'rebuild test 1' },
        },
        {
          id: EventId('evt_rb2'),
          sessionId: testSessionId,
          workspaceId: testWorkspaceId,
          parentId: EventId('evt_rb1'),
          type: 'message.assistant' as const,
          sequence: 1,
          timestamp: new Date().toISOString(),
          payload: { content: 'rebuild test 2' },
        },
      ];

      // Insert events - they are now auto-indexed via FTS triggers
      await eventRepo.insertBatch(events);
      // FTS triggers auto-insert on event insert
      expect(searchRepo.countBySession(testSessionId)).toBe(2);

      // Rebuild index should clear and re-index (same count)
      const indexed = searchRepo.rebuildSessionIndex(testSessionId);
      expect(indexed).toBe(2);
      expect(searchRepo.countBySession(testSessionId)).toBe(2);

      // Verify search works
      const results = searchRepo.search('rebuild');
      expect(results.length).toBe(2);
    });

    it('should clear existing index before rebuilding', async () => {
      const event = {
        id: EventId('evt_clear'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'original content' },
      };

      // Insert event - now auto-indexed via FTS trigger
      await eventRepo.insert(event);
      // FTS trigger auto-inserts, so count is 1
      expect(searchRepo.countBySession(testSessionId)).toBe(1);

      // Rebuild should clear and re-index (still 1 entry)
      const indexed = searchRepo.rebuildSessionIndex(testSessionId);
      expect(indexed).toBe(1);
      expect(searchRepo.countBySession(testSessionId)).toBe(1);
    });
  });
});
