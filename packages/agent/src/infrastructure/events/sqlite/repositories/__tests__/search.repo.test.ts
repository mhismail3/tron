/**
 * @fileoverview Tests for Search Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { SearchRepository } from '../../repositories/search.repo.js';
import { EventRepository } from '../../repositories/event.repo.js';
import { SessionId, EventId, WorkspaceId } from '../../../types.js';

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
        payload: { content: 'Hello world this is a test message', turn: 0 },
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
            { type: 'text' as const, text: 'First block ' },
            { type: 'text' as const, text: 'Second block' },
          ],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 20 },
          stopReason: 'end_turn' as const,
          model: 'claude-3-5-sonnet-20241022',
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
        payload: { toolCallId: 'tc_1', name: 'bash', arguments: { command: 'ls -la' }, turn: 1 },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      const results = searchRepo.searchByToolName('bash');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].eventId).toBe(eventId);
    });
  });

  describe('index memory.ledger', () => {
    it('should extract structured fields from memory.ledger events', async () => {
      const eventId = EventId('evt_mem_1');
      const event = {
        id: eventId,
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'memory.ledger' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: {
          title: 'WebSocket reconnection fix',
          entryType: 'bugfix',
          status: 'completed',
          input: 'Fix WebSocket dropping connections',
          actions: ['Rewrote reconnection handler', 'Added exponential backoff'],
          lessons: ['Never use esbuild CJS bundling for Bun production'],
          decisions: [{ choice: 'Use native WebSocket', reason: 'Better Bun compatibility' }],
          files: [{ path: 'src/ws-handler.ts', op: 'M', why: 'Fix reconnection' }],
          tags: ['websocket', 'bun'],
        },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      // Search by title keyword
      const titleResults = searchRepo.search('reconnection');
      expect(titleResults.length).toBeGreaterThan(0);
      expect(titleResults[0].eventId).toBe(eventId);

      // Search by lesson
      const lessonResults = searchRepo.search('esbuild');
      expect(lessonResults.length).toBeGreaterThan(0);

      // Search by decision
      const decisionResults = searchRepo.search('compatibility');
      expect(decisionResults.length).toBeGreaterThan(0);

      // Search by file keyword (use simple word, avoid FTS5 special chars in hyphenated paths)
      const fileResults = searchRepo.search('handler');
      expect(fileResults.length).toBeGreaterThan(0);

      // Search by tag
      const tagResults = searchRepo.search('websocket');
      expect(tagResults.length).toBeGreaterThan(0);
    });

    it('should not match memory.ledger events on non-existent content field', async () => {
      const event = {
        id: EventId('evt_mem_empty'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'memory.ledger' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: {
          title: 'Simple ledger entry',
        },
      };

      await eventRepo.insert(event);
      searchRepo.index(event);

      // Should find by title
      const results = searchRepo.search('ledger');
      expect(results.length).toBeGreaterThan(0);
    });
  });

  describe('reindexByType', () => {
    it('should re-index all events of a given type', async () => {
      const memoryEvent = {
        id: EventId('evt_reindex_1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'memory.ledger' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: {
          title: 'Reindex test entry',
          lessons: ['Reindexing works correctly'],
        },
      };

      await eventRepo.insert(memoryEvent);
      // FTS trigger auto-indexes with $.content (empty for memory.ledger)

      // Re-index with our improved extraction
      const count = searchRepo.reindexByType('memory.ledger');
      expect(count).toBe(1);

      // Now should be searchable by title
      const results = searchRepo.search('Reindex');
      expect(results.length).toBeGreaterThan(0);

      // And by lessons
      const lessonResults = searchRepo.search('Reindexing');
      expect(lessonResults.length).toBeGreaterThan(0);
    });

    it('should only re-index specified type', async () => {
      const memoryEvent = {
        id: EventId('evt_ri_mem'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'memory.ledger' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: {
          title: 'Memory entry for reindex',
        },
      };

      const messageEvent = {
        id: EventId('evt_ri_msg'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: 'Regular message content', turn: 0 },
      };

      await eventRepo.insert(memoryEvent);
      await eventRepo.insert(messageEvent);

      // Re-index only memory.ledger
      searchRepo.reindexByType('memory.ledger');

      // Message event should still be searchable (not deleted)
      const msgResults = searchRepo.search('Regular message');
      expect(msgResults.length).toBeGreaterThan(0);
    });
  });

  describe('indexBatch', () => {
    it('should index multiple events', async () => {
      const evt1 = {
        id: EventId('evt_batch_1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'First message', turn: 0 },
      };
      const evt2 = {
        id: EventId('evt_batch_2'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_batch_1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: [{ type: 'text' as const, text: 'Second message' }], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn' as const, model: 'claude-3-5-sonnet-20241022' },
      };
      const events = [evt1, evt2];

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
      const evt1 = {
        id: EventId('evt_s1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'Hello world test query', turn: 0 },
      };
      const evt2 = {
        id: EventId('evt_s2'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_s1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: [{ type: 'text' as const, text: 'Response with different content' }], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn' as const, model: 'claude-3-5-sonnet-20241022' },
      };
      const evt3 = {
        id: EventId('evt_s3'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_s2'),
        type: 'tool.call' as const,
        sequence: 2,
        timestamp: new Date().toISOString(),
        payload: { toolCallId: 'tc_1', name: 'read', arguments: { path: 'test' }, turn: 1 },
      };
      const events = [evt1, evt2, evt3];

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
        payload: { content: 'unique search term here', turn: 0 },
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
        payload: { content: 'workspace specific term', turn: 0 },
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
        payload: { toolCallId: 'tc_1', name: 'grep', arguments: { pattern: 'test' }, turn: 1 },
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
        payload: { content: 'to be removed', turn: 0 },
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
      const evt1 = {
        id: EventId('evt_rs1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'message 1', turn: 0 },
      };
      const evt2 = {
        id: EventId('evt_rs2'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_rs1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: [{ type: 'text' as const, text: 'message 2' }], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn' as const, model: 'claude-3-5-sonnet-20241022' },
      };
      const events = [evt1, evt2];

      // FTS triggers auto-index on insert
      await eventRepo.insertBatch(events);
      expect(searchRepo.countBySession(testSessionId)).toBe(2);

      const removed = searchRepo.removeBySession(testSessionId);
      // bun:sqlite includes trigger operations in changes, so just verify records are gone
      expect(removed).toBeGreaterThan(0);
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
        payload: { content: 'indexed content', turn: 0 },
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
      const evt1 = {
        id: EventId('evt_c1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'count 1', turn: 0 },
      };
      const evt2 = {
        id: EventId('evt_c2'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_c1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: [{ type: 'text' as const, text: 'count 2' }], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn' as const, model: 'claude-3-5-sonnet-20241022' },
      };
      const events = [evt1, evt2];

      // FTS triggers auto-index on insert
      await eventRepo.insertBatch(events);

      expect(searchRepo.countBySession(testSessionId)).toBe(2);
    });
  });

  describe('rebuildSessionIndex', () => {
    it('should rebuild index from events table', async () => {
      const evt1 = {
        id: EventId('evt_rb1'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'message.user' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: { content: 'rebuild test 1', turn: 0 },
      };
      const evt2 = {
        id: EventId('evt_rb2'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: EventId('evt_rb1'),
        type: 'message.assistant' as const,
        sequence: 1,
        timestamp: new Date().toISOString(),
        payload: { content: [{ type: 'text' as const, text: 'rebuild test 2' }], turn: 1, tokenUsage: { inputTokens: 10, outputTokens: 20 }, stopReason: 'end_turn' as const, model: 'claude-3-5-sonnet-20241022' },
      };
      const events = [evt1, evt2];

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

    it('should properly index memory.ledger events on rebuild', async () => {
      const memoryEvent = {
        id: EventId('evt_mem_rb'),
        sessionId: testSessionId,
        workspaceId: testWorkspaceId,
        parentId: null,
        type: 'memory.ledger' as const,
        sequence: 0,
        timestamp: new Date().toISOString(),
        payload: {
          title: 'OAuth implementation',
          entryType: 'feature',
          status: 'completed',
          input: 'Add Google OAuth login',
          actions: ['Created auth module', 'Added passport integration'],
          lessons: ['Use passport.js for OAuth providers'],
          files: [{ path: 'src/auth.ts', op: 'C', why: 'New auth module' }],
          tags: ['auth', 'security'],
        },
      };

      await eventRepo.insert(memoryEvent);
      // Rebuild to use our extraction logic (trigger may extract $.content which is empty)
      searchRepo.rebuildSessionIndex(testSessionId);

      // Should find by title
      const titleResults = searchRepo.search('OAuth');
      expect(titleResults.length).toBeGreaterThan(0);
      expect(titleResults[0].eventId).toBe(EventId('evt_mem_rb'));

      // Should find by lesson content
      const lessonResults = searchRepo.search('passport');
      expect(lessonResults.length).toBeGreaterThan(0);

      // Should find by file keyword
      const fileResults = searchRepo.search('auth');
      expect(fileResults.length).toBeGreaterThan(0);

      // Should find by action keyword
      const actionResults = searchRepo.search('passport');
      expect(actionResults.length).toBeGreaterThan(0);
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
        payload: { content: 'original content', turn: 0 },
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
