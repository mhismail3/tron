/**
 * @fileoverview Tests for Remember tool
 *
 * Tests the agent's ability to query its own database for memory recall,
 * session debugging, and self-analysis.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Database } from 'bun:sqlite';
import { RememberTool } from '../system/remember.js';

describe('RememberTool', () => {
  let dbPath: string;
  let db: Database;
  let tool: RememberTool;

  beforeEach(() => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'remember-test-'));
    dbPath = path.join(tmpDir, 'test.db');
    db = new Database(dbPath);

    db.exec(`
      CREATE TABLE workspaces (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        name TEXT
      );

      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT,
        title TEXT,
        created_at TEXT NOT NULL,
        last_activity_at TEXT,
        event_count INTEGER DEFAULT 0,
        turn_count INTEGER DEFAULT 0,
        total_input_tokens INTEGER DEFAULT 0,
        total_output_tokens INTEGER DEFAULT 0,
        total_cost REAL DEFAULT 0,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
      );

      CREATE TABLE events (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        turn INTEGER,
        tool_name TEXT,
        tool_call_id TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        payload TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(id)
      );

      CREATE TABLE blobs (
        id TEXT PRIMARY KEY,
        hash TEXT NOT NULL UNIQUE,
        content BLOB NOT NULL,
        mime_type TEXT NOT NULL DEFAULT 'text/plain',
        size_original INTEGER NOT NULL,
        size_compressed INTEGER NOT NULL,
        compression TEXT NOT NULL DEFAULT 'none',
        ref_count INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      );

      CREATE TABLE logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        level_num INTEGER NOT NULL,
        component TEXT,
        message TEXT NOT NULL,
        error_message TEXT,
        error_stack TEXT
      );
    `);

    tool = new RememberTool({ dbPath });
  });

  afterEach(() => {
    tool.close();
    db.close();
    if (dbPath) {
      const tmpDir = path.dirname(dbPath);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  // ===========================================================================
  // Tool definition
  // ===========================================================================

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('Remember');
    });

    it('should mention memory in description', () => {
      expect(tool.description).toContain('memory');
    });

    it('should define action parameter with all actions', () => {
      const params = tool.parameters;
      expect(params.properties).toHaveProperty('action');
      expect(params.required).toContain('action');
      expect(params.properties.action.enum).toContain('memory');
      expect(params.properties.action.enum).toContain('read_blob');
    });

    it('should define optional parameters', () => {
      const params = tool.parameters;
      expect(params.properties).toHaveProperty('session_id');
      expect(params.properties).toHaveProperty('blob_id');
      expect(params.properties).toHaveProperty('limit');
    });
  });

  // ===========================================================================
  // Input validation
  // ===========================================================================

  describe('input validation', () => {
    it('should cap limit at 500', async () => {
      // Insert many sessions
      for (let i = 0; i < 10; i++) {
        db.exec(`INSERT INTO sessions (id, created_at, last_activity_at) VALUES ('sess_${i}', '2024-01-15T10:00:00Z', '2024-01-15T10:00:00Z')`);
      }

      const result = await tool.execute({ action: 'sessions', limit: 99999 });
      expect(result.isError).toBe(false);
      // Should not crash — limit is capped internally
    });

    it('should handle zero limit gracefully', async () => {
      const result = await tool.execute({ action: 'sessions', limit: 0 });
      expect(result.isError).toBe(false);
    });

    it('should handle negative offset gracefully', async () => {
      const result = await tool.execute({ action: 'sessions', offset: -5 });
      expect(result.isError).toBe(false);
    });
  });

  // ===========================================================================
  // Resource management
  // ===========================================================================

  describe('resource management', () => {
    it('should have a close method', () => {
      expect(typeof tool.close).toBe('function');
    });

    it('should handle multiple close calls', () => {
      tool.close();
      tool.close(); // Should not throw
    });
  });

  // ===========================================================================
  // Schema action
  // ===========================================================================

  describe('schema action', () => {
    it('should return database schema', async () => {
      const result = await tool.execute({ action: 'schema' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Database Schema');
      expect(result.content).toContain('sessions');
      expect(result.content).toContain('events');
      expect(result.content).toContain('blobs');
    });

    it('should include tips', async () => {
      const result = await tool.execute({ action: 'schema' });

      expect(result.content).toContain('Tips');
      expect(result.content).toContain('read_blob');
    });
  });

  // ===========================================================================
  // Sessions action
  // ===========================================================================

  describe('sessions action', () => {
    it('should return empty message when no sessions', async () => {
      const result = await tool.execute({ action: 'sessions' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('No sessions found');
    });

    it('should list sessions', async () => {
      db.exec(`
        INSERT INTO sessions (id, title, created_at, last_activity_at, event_count, turn_count, total_cost)
        VALUES ('sess_abc123', 'Test Session', '2024-01-15T10:00:00Z', '2024-01-15T11:00:00Z', 50, 5, 0.0123)
      `);

      const result = await tool.execute({ action: 'sessions' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('sess_abc123');
      expect(result.content).toContain('Test Session');
      expect(result.content).toContain('Events: 50');
      expect(result.content).toContain('Turns: 5');
    });

    it('should respect limit parameter', async () => {
      db.exec(`
        INSERT INTO sessions (id, title, created_at, last_activity_at) VALUES
        ('sess_1', 'Session 1', '2024-01-15T10:00:00Z', '2024-01-15T10:00:00Z'),
        ('sess_2', 'Session 2', '2024-01-15T11:00:00Z', '2024-01-15T11:00:00Z'),
        ('sess_3', 'Session 3', '2024-01-15T12:00:00Z', '2024-01-15T12:00:00Z')
      `);

      const result = await tool.execute({ action: 'sessions', limit: 2 });

      expect(result.content).toContain('sess_3');
      expect(result.content).toContain('sess_2');
      expect(result.content).not.toContain('sess_1');
    });
  });

  // ===========================================================================
  // Session action
  // ===========================================================================

  describe('session action', () => {
    it('should require session_id', async () => {
      const result = await tool.execute({ action: 'session' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('session_id is required');
    });

    it('should return session details', async () => {
      db.exec(`
        INSERT INTO workspaces (id, path, name) VALUES ('ws_1', '/test/project', 'Test Project');
        INSERT INTO sessions (id, workspace_id, title, created_at, total_cost)
        VALUES ('sess_abc123', 'ws_1', 'Test Session', '2024-01-15T10:00:00Z', 0.05)
      `);

      const result = await tool.execute({ action: 'session', session_id: 'sess_abc123' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Session Details');
      expect(result.content).toContain('sess_abc123');
      expect(result.content).toContain('Test Session');
      expect(result.content).toContain('/test/project');
    });

    it('should support prefix matching', async () => {
      db.exec(`
        INSERT INTO sessions (id, title, created_at)
        VALUES ('sess_xyz789def456', 'Prefix Test', '2024-01-15T10:00:00Z')
      `);

      const result = await tool.execute({ action: 'session', session_id: 'sess_xyz' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('sess_xyz789def456');
      expect(result.content).toContain('Prefix Test');
    });

    it('should return error for non-existent session', async () => {
      const result = await tool.execute({ action: 'session', session_id: 'nonexistent' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Session not found');
    });
  });

  // ===========================================================================
  // Events action
  // ===========================================================================

  describe('events action', () => {
    it('should return events', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, turn, payload)
        VALUES ('evt_1', 'sess_1', 1, 'message.user', '2024-01-15T10:00:00Z', 1, '{"content":"Hello"}')
      `);

      const result = await tool.execute({ action: 'events', session_id: 'sess_1' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('message.user');
      expect(result.content).toContain('Hello');
    });

    it('should filter by type', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES
        ('evt_1', 'sess_1', 1, 'message.user', '2024-01-15T10:00:00Z', '{}'),
        ('evt_2', 'sess_1', 2, 'message.assistant', '2024-01-15T10:01:00Z', '{}'),
        ('evt_3', 'sess_1', 3, 'tool.call', '2024-01-15T10:02:00Z', '{}')
      `);

      const result = await tool.execute({ action: 'events', session_id: 'sess_1', type: 'tool' });

      expect(result.content).toContain('tool.call');
      expect(result.content).not.toContain('message.user');
    });

    it('should filter by turn', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, turn, payload) VALUES
        ('evt_1', 'sess_1', 1, 'message.user', '2024-01-15T10:00:00Z', 1, '{}'),
        ('evt_2', 'sess_1', 2, 'message.assistant', '2024-01-15T10:01:00Z', 1, '{}'),
        ('evt_3', 'sess_1', 3, 'message.user', '2024-01-15T10:02:00Z', 2, '{}')
      `);

      const result = await tool.execute({ action: 'events', session_id: 'sess_1', turn: 2 });

      expect(result.content).toContain('[3]');
      expect(result.content).not.toContain('[1]');
      expect(result.content).not.toContain('[2]');
    });
  });

  // ===========================================================================
  // Messages action
  // ===========================================================================

  describe('messages action', () => {
    it('should require session_id', async () => {
      const result = await tool.execute({ action: 'messages' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('session_id is required');
    });

    it('should return messages only', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, turn, payload) VALUES
        ('evt_1', 'sess_1', 1, 'message.user', '2024-01-15T10:00:00Z', 1, '{"content":"Hello"}'),
        ('evt_2', 'sess_1', 2, 'tool.call', '2024-01-15T10:01:00Z', 1, '{}'),
        ('evt_3', 'sess_1', 3, 'message.assistant', '2024-01-15T10:02:00Z', 1, '{"content":"Hi there!"}')
      `);

      const result = await tool.execute({ action: 'messages', session_id: 'sess_1' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('USER');
      expect(result.content).toContain('ASSISTANT');
      expect(result.content).toContain('Hello');
      expect(result.content).not.toContain('tool.call');
    });
  });

  // ===========================================================================
  // Tools action
  // ===========================================================================

  describe('tools action', () => {
    it('should require session_id', async () => {
      const result = await tool.execute({ action: 'tools' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('session_id is required');
    });

    it('should return tool calls and results', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, tool_name, payload) VALUES
        ('evt_1', 'sess_1', 1, 'tool.call', '2024-01-15T10:00:00Z', 'Read', '{"arguments":{"file_path":"/test.txt"}}'),
        ('evt_2', 'sess_1', 2, 'tool.result', '2024-01-15T10:01:00Z', 'Read', '{"content":"file contents"}')
      `);

      const result = await tool.execute({ action: 'tools', session_id: 'sess_1' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('CALL');
      expect(result.content).toContain('RESULT');
      expect(result.content).toContain('Read');
      expect(result.content).toContain('file_path');
    });

    it('should indicate blob storage', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, tool_name, payload) VALUES
        ('evt_1', 'sess_1', 1, 'tool.result', '2024-01-15T10:00:00Z', 'Read', '{"content":"short","blobId":"blob_abc123"}')
      `);

      const result = await tool.execute({ action: 'tools', session_id: 'sess_1' });

      expect(result.content).toContain('blob_abc123');
      expect(result.content).toContain('Stored in blob');
    });
  });

  // ===========================================================================
  // Logs action
  // ===========================================================================

  describe('logs action', () => {
    it('should return logs', async () => {
      db.exec(`
        INSERT INTO logs (session_id, timestamp, level, level_num, component, message)
        VALUES ('sess_1', '2024-01-15T10:00:00Z', 'info', 30, 'TestComponent', 'Test log message')
      `);

      const result = await tool.execute({ action: 'logs' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('INFO');
      expect(result.content).toContain('TestComponent');
      expect(result.content).toContain('Test log message');
    });

    it('should filter by level', async () => {
      db.exec(`
        INSERT INTO logs (session_id, timestamp, level, level_num, component, message) VALUES
        ('sess_1', '2024-01-15T10:00:00Z', 'debug', 20, 'Test', 'Debug message'),
        ('sess_1', '2024-01-15T10:01:00Z', 'error', 50, 'Test', 'Error message')
      `);

      const result = await tool.execute({ action: 'logs', level: 'error' });

      expect(result.content).toContain('Error message');
      expect(result.content).not.toContain('Debug message');
    });

    it('should filter by session', async () => {
      db.exec(`
        INSERT INTO logs (session_id, timestamp, level, level_num, component, message) VALUES
        ('sess_1', '2024-01-15T10:00:00Z', 'info', 30, 'Test', 'Session 1 log'),
        ('sess_2', '2024-01-15T10:01:00Z', 'info', 30, 'Test', 'Session 2 log')
      `);

      const result = await tool.execute({ action: 'logs', session_id: 'sess_1' });

      expect(result.content).toContain('Session 1 log');
      expect(result.content).not.toContain('Session 2 log');
    });
  });

  // ===========================================================================
  // Stats action
  // ===========================================================================

  describe('stats action', () => {
    it('should return database statistics', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at, total_cost) VALUES
        ('sess_1', '2024-01-15T10:00:00Z', 0.05),
        ('sess_2', '2024-01-15T11:00:00Z', 0.03);
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES
        ('evt_1', 'sess_1', 1, 'message.user', '2024-01-15T10:00:00Z', '{}'),
        ('evt_2', 'sess_1', 2, 'message.assistant', '2024-01-15T10:01:00Z', '{}');
        INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, created_at)
        VALUES ('blob_1', 'abc123', X'48656C6C6F', 'text/plain', 5, 5, '2024-01-15T10:00:00Z');
      `);

      const result = await tool.execute({ action: 'stats' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Sessions: 2');
      expect(result.content).toContain('Events: 2');
      expect(result.content).toContain('Blobs: 1');
      expect(result.content).toContain('Total cost');
    });
  });

  // ===========================================================================
  // Read blob action
  // ===========================================================================

  describe('read_blob action', () => {
    it('should require blob_id', async () => {
      const result = await tool.execute({ action: 'read_blob' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('blob_id is required');
    });

    it('should return blob content', async () => {
      const content = 'This is the full blob content that was stored.';
      db.prepare(`
        INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, created_at)
        VALUES (?, ?, ?, 'text/plain', ?, ?, '2024-01-15T10:00:00Z')
      `).run('blob_test123', 'hash123', Buffer.from(content), content.length, content.length);

      const result = await tool.execute({ action: 'read_blob', blob_id: 'blob_test123' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Blob: blob_test123');
      expect(result.content).toContain(`Size: ${content.length}`);
      expect(result.content).toContain('text/plain');
      expect(result.content).toContain('This is the full blob content');
    });

    it('should return error for non-existent blob', async () => {
      const result = await tool.execute({ action: 'read_blob', blob_id: 'nonexistent' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Blob not found');
    });

    it('should include details in result', async () => {
      db.exec(`
        INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, created_at)
        VALUES ('blob_details', 'hashXYZ', X'48656C6C6F', 'text/plain', 5, 5, '2024-01-15T10:00:00Z')
      `);

      const result = await tool.execute({ action: 'read_blob', blob_id: 'blob_details' });

      expect(result.details).toBeDefined();
      expect(result.details).toHaveProperty('blobId', 'blob_details');
      expect(result.details).toHaveProperty('hash', 'hashXYZ');
      expect(result.details).toHaveProperty('sizeOriginal', 5);
    });
  });

  // ===========================================================================
  // Memory action
  // ===========================================================================

  describe('memory action', () => {
    it('should return empty message when no entries', async () => {
      const result = await tool.execute({ action: 'memory' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('No memory ledger entries found');
    });

    it('should return ledger entries with all fields', async () => {
      const payload = JSON.stringify({
        title: 'Add user auth',
        entryType: 'feature',
        status: 'completed',
        input: 'Add OAuth login flow',
        actions: ['Created auth module', 'Added Google provider'],
        files: [{ path: 'src/auth.ts', op: 'C', why: 'New auth module' }],
        lessons: ['Use passport.js for OAuth'],
        tags: ['auth', 'oauth'],
      });

      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload)
        VALUES ('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', '${payload.replace(/'/g, "''")}')
      `);

      const result = await tool.execute({ action: 'memory' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Add user auth');
      expect(result.content).toContain('feature');
      expect(result.content).toContain('completed');
      expect(result.content).toContain('Add OAuth login flow');
      expect(result.content).toContain('Created auth module');
      expect(result.content).toContain('src/auth.ts');
      expect(result.content).toContain('Use passport.js for OAuth');
    });

    it('should filter by session_id', async () => {
      db.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO sessions (id, created_at) VALUES ('sess_2', '2024-01-15T11:00:00Z');
      `);

      const payload1 = JSON.stringify({ title: 'Session 1 work', entryType: 'feature' });
      const payload2 = JSON.stringify({ title: 'Session 2 work', entryType: 'bugfix' });

      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', payload1);
      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_2', 'sess_2', 1, 'memory.ledger', '2024-01-15T11:30:00Z', payload2);

      const result = await tool.execute({ action: 'memory', session_id: 'sess_1' });

      expect(result.content).toContain('Session 1 work');
      expect(result.content).not.toContain('Session 2 work');
    });

    it('should handle large payloads without truncation', async () => {
      // Create a payload that exceeds 2000 chars (the old truncation limit)
      const longLessons = Array.from({ length: 50 }, (_, i) =>
        `Lesson ${i}: This is a detailed lesson about software architecture patterns and best practices that spans multiple words.`
      );
      const payload = JSON.stringify({
        title: 'Large entry',
        entryType: 'research',
        status: 'completed',
        input: 'Research complex topic',
        actions: ['Did extensive research'],
        lessons: longLessons,
      });

      // Verify payload is >2000 chars
      expect(payload.length).toBeGreaterThan(2000);

      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);
      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', payload);

      const result = await tool.execute({ action: 'memory', session_id: 'sess_1' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Large entry');
      // Should contain lessons from the end of the array (proves no truncation)
      expect(result.content).toContain('Lesson 49');
      expect(result.content).not.toContain('could not parse');
    });

    it('should handle entries with missing optional fields', async () => {
      const payload = JSON.stringify({ title: 'Minimal entry' });

      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);
      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', payload);

      const result = await tool.execute({ action: 'memory' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Minimal entry');
    });

    it('should handle malformed JSON payload gracefully', async () => {
      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);
      db.exec(`
        INSERT INTO events (id, session_id, sequence, type, timestamp, payload)
        VALUES ('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', 'not valid json{{{')
      `);

      const result = await tool.execute({ action: 'memory' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('could not parse');
    });

    it('should support pagination with limit and offset', async () => {
      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      for (let i = 0; i < 5; i++) {
        const payload = JSON.stringify({ title: `Entry ${i}`, entryType: 'feature' });
        db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
          .run(`evt_${i}`, 'sess_1', i + 1, 'memory.ledger', `2024-01-15T10:0${i}:00Z`, payload);
      }

      // Get first 2 (most recent)
      const page1 = await tool.execute({ action: 'memory', limit: 2 });
      expect(page1.content).toContain('Entry 4');
      expect(page1.content).toContain('Entry 3');
      expect(page1.content).not.toContain('Entry 2');

      // Get next 2
      const page2 = await tool.execute({ action: 'memory', limit: 2, offset: 2 });
      expect(page2.content).toContain('Entry 2');
      expect(page2.content).toContain('Entry 1');
      expect(page2.content).not.toContain('Entry 4');
    });

    it('should support session_id prefix matching', async () => {
      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_abc123def', '2024-01-15T10:00:00Z')`);

      const payload = JSON.stringify({ title: 'Prefix match test' });
      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_1', 'sess_abc123def', 1, 'memory.ledger', '2024-01-15T10:30:00Z', payload);

      const result = await tool.execute({ action: 'memory', session_id: 'sess_abc' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Prefix match test');
    });

    it('should filter by query keyword (LIKE fallback without FTS)', async () => {
      // Without events_fts table, query falls through to no-query path
      // (FTS table not created in test setup)
      db.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      const payload1 = JSON.stringify({ title: 'OAuth implementation', entryType: 'feature', lessons: ['Use passport.js'] });
      const payload2 = JSON.stringify({ title: 'Database migration', entryType: 'feature', lessons: ['Use knex'] });

      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_1', 'sess_1', 1, 'memory.ledger', '2024-01-15T10:30:00Z', payload1);
      db.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run('evt_2', 'sess_1', 2, 'memory.ledger', '2024-01-15T10:31:00Z', payload2);

      // Without FTS, returns all entries (query has no effect on direct scan)
      const result = await tool.execute({ action: 'memory', query: 'OAuth' });
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Memory Ledger');
    });
  });

  // ===========================================================================
  // Memory action with FTS5
  // ===========================================================================

  describe('memory action with FTS5', () => {
    let ftsTool: RememberTool;
    let ftsDb: Database;
    let ftsDbPath: string;

    beforeEach(() => {
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'remember-fts-test-'));
      ftsDbPath = path.join(tmpDir, 'test-fts.db');
      ftsDb = new Database(ftsDbPath);

      // Create schema with FTS5 table
      ftsDb.exec(`
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          workspace_id TEXT,
          title TEXT,
          created_at TEXT NOT NULL,
          last_activity_at TEXT,
          event_count INTEGER DEFAULT 0,
          turn_count INTEGER DEFAULT 0,
          total_input_tokens INTEGER DEFAULT 0,
          total_output_tokens INTEGER DEFAULT 0,
          total_cost REAL DEFAULT 0
        );

        CREATE TABLE events (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          type TEXT NOT NULL,
          timestamp TEXT NOT NULL,
          turn INTEGER,
          tool_name TEXT,
          tool_call_id TEXT,
          input_tokens INTEGER,
          output_tokens INTEGER,
          payload TEXT,
          FOREIGN KEY (session_id) REFERENCES sessions(id)
        );

        CREATE VIRTUAL TABLE events_fts USING fts5(
          id,
          session_id,
          type,
          content,
          tool_name,
          tokenize='porter unicode61'
        );
      `);

      ftsTool = new RememberTool({ dbPath: ftsDbPath });
    });

    afterEach(() => {
      ftsTool.close();
      ftsDb.close();
      if (ftsDbPath) {
        const tmpDir = path.dirname(ftsDbPath);
        fs.rmSync(tmpDir, { recursive: true, force: true });
      }
    });

    function insertMemoryWithFts(id: string, sessionId: string, timestamp: string, payload: Record<string, unknown>) {
      const payloadStr = JSON.stringify(payload);
      ftsDb.prepare(`INSERT INTO events (id, session_id, sequence, type, timestamp, payload) VALUES (?, ?, ?, ?, ?, ?)`)
        .run(id, sessionId, 1, 'memory.ledger', timestamp, payloadStr);

      // Manually index into FTS (since we don't have the trigger in test)
      const parts: string[] = [];
      if (typeof payload.title === 'string') parts.push(payload.title);
      if (typeof payload.input === 'string') parts.push(payload.input);
      if (typeof payload.entryType === 'string') parts.push(payload.entryType as string);
      if (typeof payload.status === 'string') parts.push(payload.status as string);
      if (Array.isArray(payload.actions)) parts.push(...(payload.actions as string[]));
      if (Array.isArray(payload.lessons)) parts.push(...(payload.lessons as string[]));
      if (Array.isArray(payload.tags)) parts.push(...(payload.tags as string[]));

      ftsDb.prepare(`INSERT INTO events_fts (id, session_id, type, content, tool_name) VALUES (?, ?, 'memory.ledger', ?, '')`)
        .run(id, sessionId, parts.join(' '));
    }

    it('should search memory by query using FTS5', async () => {
      ftsDb.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      insertMemoryWithFts('evt_1', 'sess_1', '2024-01-15T10:30:00Z', {
        title: 'OAuth implementation',
        entryType: 'feature',
        status: 'completed',
        input: 'Add Google OAuth login',
        actions: ['Created auth module', 'Added passport integration'],
        lessons: ['Use passport.js for OAuth providers'],
      });

      insertMemoryWithFts('evt_2', 'sess_1', '2024-01-15T10:31:00Z', {
        title: 'Database migration system',
        entryType: 'feature',
        status: 'completed',
        input: 'Set up database migrations',
        actions: ['Created migration runner'],
        lessons: ['Use knex for migrations'],
      });

      const result = await ftsTool.execute({ action: 'memory', query: 'OAuth' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('OAuth implementation');
      // FTS ranked search should not return the unrelated entry (or rank it lower)
      expect(result.content).not.toContain('Database migration');
    });

    it('should search across lessons and actions', async () => {
      ftsDb.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      insertMemoryWithFts('evt_1', 'sess_1', '2024-01-15T10:30:00Z', {
        title: 'WebSocket improvements',
        entryType: 'bugfix',
        actions: ['Fixed reconnection logic'],
        lessons: ['Never use esbuild CJS bundling for Bun production'],
      });

      insertMemoryWithFts('evt_2', 'sess_1', '2024-01-15T10:31:00Z', {
        title: 'API endpoint cleanup',
        entryType: 'refactor',
        actions: ['Cleaned up REST endpoints'],
      });

      const result = await ftsTool.execute({ action: 'memory', query: 'esbuild' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('WebSocket improvements');
      expect(result.content).toContain('esbuild');
      expect(result.content).not.toContain('API endpoint');
    });

    it('should show "no results" message with search context', async () => {
      ftsDb.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      const result = await ftsTool.execute({ action: 'memory', query: 'nonexistent_topic' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('No memory ledger entries found matching "nonexistent_topic"');
    });

    it('should combine query with session_id filter', async () => {
      ftsDb.exec(`
        INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z');
        INSERT INTO sessions (id, created_at) VALUES ('sess_2', '2024-01-15T11:00:00Z');
      `);

      insertMemoryWithFts('evt_1', 'sess_1', '2024-01-15T10:30:00Z', {
        title: 'Auth work in session 1',
        entryType: 'feature',
        lessons: ['OAuth is tricky'],
      });

      insertMemoryWithFts('evt_2', 'sess_2', '2024-01-15T11:30:00Z', {
        title: 'Auth work in session 2',
        entryType: 'feature',
        lessons: ['OAuth needs refresh tokens'],
      });

      const result = await ftsTool.execute({ action: 'memory', query: 'OAuth', session_id: 'sess_1' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Auth work in session 1');
      expect(result.content).not.toContain('Auth work in session 2');
    });

    it('should return all entries when no query provided (even with FTS table)', async () => {
      ftsDb.exec(`INSERT INTO sessions (id, created_at) VALUES ('sess_1', '2024-01-15T10:00:00Z')`);

      insertMemoryWithFts('evt_1', 'sess_1', '2024-01-15T10:30:00Z', {
        title: 'First entry',
        entryType: 'feature',
      });

      insertMemoryWithFts('evt_2', 'sess_1', '2024-01-15T10:31:00Z', {
        title: 'Second entry',
        entryType: 'bugfix',
      });

      const result = await ftsTool.execute({ action: 'memory' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('First entry');
      expect(result.content).toContain('Second entry');
    });
  });

  // ===========================================================================
  // Unknown action
  // ===========================================================================

  describe('unknown action', () => {
    it('should return error for unknown action', async () => {
      const result = await tool.execute({ action: 'unknown_action' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });
  });

  // ===========================================================================
  // Error handling
  // ===========================================================================

  describe('error handling', () => {
    it('should handle database errors gracefully', async () => {
      const badTool = new RememberTool({ dbPath: '/nonexistent/path/db.sqlite' });

      const result = await badTool.execute({ action: 'schema' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Error');
    });
  });
});
