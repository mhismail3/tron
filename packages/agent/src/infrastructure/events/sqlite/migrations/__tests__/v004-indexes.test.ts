/**
 * @fileoverview Tests for v004 Migration - Indexes and FTS Triggers
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Database } from 'bun:sqlite';
import { runMigrations } from '../index.js';

describe('v004 migration - indexes', () => {
  let db: Database;

  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  afterEach(() => {
    db?.close();
  });

  describe('index creation', () => {
    it('should create idx_events_tool_call_id index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_events_tool_call_id'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });

    it('should create idx_blobs_ref_count index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_blobs_ref_count'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });

    it('should create idx_sessions_created index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_sessions_created'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });

    it('should create idx_events_message_preview index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_events_message_preview'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });

    it('should create idx_events_session_covering index', () => {
      const indexes = db
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_events_session_covering'")
        .all() as { name: string }[];
      expect(indexes).toHaveLength(1);
    });
  });

  describe('index usage in query plans', () => {
    it('should use tool_call_id index for tool call queries', () => {
      const plan = db
        .prepare("EXPLAIN QUERY PLAN SELECT * FROM events WHERE tool_call_id = 'test'")
        .all() as { detail: string }[];
      // Should use the partial index
      const usesIndex = plan.some((p) => p.detail?.includes('idx_events_tool_call_id'));
      expect(usesIndex).toBe(true);
    });

    it('should use blobs ref_count index for cleanup queries', () => {
      const plan = db
        .prepare('EXPLAIN QUERY PLAN SELECT * FROM blobs WHERE ref_count <= 0')
        .all() as { detail: string }[];
      // Should use the partial index
      const usesIndex = plan.some((p) => p.detail?.includes('idx_blobs_ref_count'));
      expect(usesIndex).toBe(true);
    });

    it('should use sessions created_at index for ordering', () => {
      const plan = db
        .prepare('EXPLAIN QUERY PLAN SELECT * FROM sessions ORDER BY created_at DESC LIMIT 10')
        .all() as { detail: string }[];
      // Should use the index for ordering
      const usesIndex = plan.some((p) => p.detail?.includes('idx_sessions_created'));
      expect(usesIndex).toBe(true);
    });
  });
});

describe('v004 migration - FTS triggers', () => {
  let db: Database;

  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  afterEach(() => {
    db?.close();
  });

  describe('trigger creation', () => {
    it('should create events_fts_insert trigger', () => {
      const triggers = db
        .prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name='events_fts_insert'")
        .all() as { name: string }[];
      expect(triggers).toHaveLength(1);
    });

    it('should create events_fts_delete trigger', () => {
      const triggers = db
        .prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name='events_fts_delete'")
        .all() as { name: string }[];
      expect(triggers).toHaveLength(1);
    });

    it('should create logs_fts_insert trigger', () => {
      const triggers = db
        .prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name='logs_fts_insert'")
        .all() as { name: string }[];
      expect(triggers).toHaveLength(1);
    });

    it('should create logs_fts_delete trigger', () => {
      const triggers = db
        .prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name='logs_fts_delete'")
        .all() as { name: string }[];
      expect(triggers).toHaveLength(1);
    });
  });

  describe('events FTS auto-sync', () => {
    it('should auto-insert into events_fts on event insert', () => {
      // Create a workspace first (foreign key requirement)
      db.prepare(
        `INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
         VALUES ('ws1', '/test', 'Test', datetime('now'), datetime('now'))`
      ).run();

      // Create a session (foreign key requirement)
      db.prepare(
        `INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('s1', 'ws1', 'claude-3', '/test', datetime('now'), datetime('now'))`
      ).run();

      // Insert an event
      db.prepare(
        `INSERT INTO events (id, session_id, sequence, depth, type, timestamp, payload, workspace_id)
         VALUES ('e1', 's1', 1, 0, 'message.user', datetime('now'), '{"content":"Hello world"}', 'ws1')`
      ).run();

      // Verify FTS entry was created
      const ftsEntry = db.prepare('SELECT * FROM events_fts WHERE id = ?').get('e1') as {
        id: string;
        content: string;
      } | undefined;
      expect(ftsEntry).toBeDefined();
      expect(ftsEntry?.id).toBe('e1');
    });

    it('should auto-delete from events_fts on event delete', () => {
      // Create a workspace first
      db.prepare(
        `INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
         VALUES ('ws1', '/test', 'Test', datetime('now'), datetime('now'))`
      ).run();

      // Create a session
      db.prepare(
        `INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('s1', 'ws1', 'claude-3', '/test', datetime('now'), datetime('now'))`
      ).run();

      // Insert and then delete an event
      db.prepare(
        `INSERT INTO events (id, session_id, sequence, depth, type, timestamp, payload, workspace_id)
         VALUES ('e1', 's1', 1, 0, 'message.user', datetime('now'), '{"content":"Hello"}', 'ws1')`
      ).run();

      // Delete the event
      db.prepare('DELETE FROM events WHERE id = ?').run('e1');

      // Verify FTS entry was removed
      const ftsCount = db.prepare('SELECT COUNT(*) as c FROM events_fts WHERE id = ?').get('e1') as {
        c: number;
      };
      expect(ftsCount.c).toBe(0);
    });

    it('should extract content from payload for FTS', () => {
      // Create workspace and session
      db.prepare(
        `INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
         VALUES ('ws1', '/test', 'Test', datetime('now'), datetime('now'))`
      ).run();

      db.prepare(
        `INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('s1', 'ws1', 'claude-3', '/test', datetime('now'), datetime('now'))`
      ).run();

      // Insert event with content in payload
      db.prepare(
        `INSERT INTO events (id, session_id, sequence, depth, type, timestamp, payload, workspace_id)
         VALUES ('e1', 's1', 1, 0, 'message.user', datetime('now'), '{"content":"searchable text here"}', 'ws1')`
      ).run();

      // Search FTS for the content
      const results = db
        .prepare("SELECT * FROM events_fts WHERE events_fts MATCH 'searchable'")
        .all() as { id: string }[];
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].id).toBe('e1');
    });

    it('should extract tool_name from payload for FTS', () => {
      // Create workspace and session
      db.prepare(
        `INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
         VALUES ('ws1', '/test', 'Test', datetime('now'), datetime('now'))`
      ).run();

      db.prepare(
        `INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('s1', 'ws1', 'claude-3', '/test', datetime('now'), datetime('now'))`
      ).run();

      // Insert event with toolName in payload
      db.prepare(
        `INSERT INTO events (id, session_id, sequence, depth, type, timestamp, payload, workspace_id, tool_name)
         VALUES ('e1', 's1', 1, 0, 'tool.call', datetime('now'), '{"toolName":"ReadFile"}', 'ws1', 'ReadFile')`
      ).run();

      // Search FTS for the tool name
      const results = db
        .prepare("SELECT * FROM events_fts WHERE events_fts MATCH 'ReadFile'")
        .all() as { id: string }[];
      expect(results.length).toBeGreaterThan(0);
    });
  });

  describe('logs FTS auto-sync', () => {
    it('should auto-insert into logs_fts on log insert', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (datetime('now'), 'INFO', 2, 'test-component', 'test log message')`
      ).run();

      // Get the log id
      const log = db.prepare('SELECT id FROM logs ORDER BY id DESC LIMIT 1').get() as { id: number };

      // Verify FTS entry was created
      const ftsEntry = db.prepare('SELECT * FROM logs_fts WHERE log_id = ?').get(log.id) as {
        log_id: number;
        message: string;
      } | undefined;
      expect(ftsEntry).toBeDefined();
      expect(ftsEntry?.message).toBe('test log message');
    });

    it('should auto-delete from logs_fts on log delete', () => {
      db.prepare(
        `INSERT INTO logs (timestamp, level, level_num, component, message)
         VALUES (datetime('now'), 'INFO', 2, 'test-component', 'test log')`
      ).run();

      const log = db.prepare('SELECT id FROM logs ORDER BY id DESC LIMIT 1').get() as { id: number };

      // Delete the log
      db.prepare('DELETE FROM logs WHERE id = ?').run(log.id);

      // Verify FTS entry was removed
      const ftsCount = db.prepare('SELECT COUNT(*) as c FROM logs_fts WHERE log_id = ?').get(log.id) as {
        c: number;
      };
      expect(ftsCount.c).toBe(0);
    });
  });
});
