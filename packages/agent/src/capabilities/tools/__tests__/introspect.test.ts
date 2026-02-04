/**
 * @fileoverview Tests for Introspect tool
 *
 * Tests database introspection functionality for agent self-analysis.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Database } from 'bun:sqlite';
import { IntrospectTool } from '../system/introspect.js';

describe('IntrospectTool', () => {
  let dbPath: string;
  let db: Database;
  let tool: IntrospectTool;

  beforeEach(() => {
    // Create temp database
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'introspect-test-'));
    dbPath = path.join(tmpDir, 'test.db');
    db = new Database(dbPath);

    // Create minimal schema
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

    tool = new IntrospectTool({ dbPath });
  });

  afterEach(() => {
    db.close();
    // Clean up temp directory
    if (dbPath) {
      const tmpDir = path.dirname(dbPath);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(tool.name).toBe('Introspect');
      expect(tool.description).toContain('database');
      expect(tool.description).toContain('debugging');
    });

    it('should define action parameter', () => {
      const params = tool.parameters;
      expect(params.properties).toHaveProperty('action');
      expect(params.required).toContain('action');
    });

    it('should define optional parameters', () => {
      const params = tool.parameters;
      expect(params.properties).toHaveProperty('session_id');
      expect(params.properties).toHaveProperty('blob_id');
      expect(params.properties).toHaveProperty('limit');
    });
  });

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

  describe('unknown action', () => {
    it('should return error for unknown action', async () => {
      const result = await tool.execute({ action: 'unknown_action' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });
  });

  describe('error handling', () => {
    it('should handle database errors gracefully', async () => {
      // Create tool with invalid path
      const badTool = new IntrospectTool({ dbPath: '/nonexistent/path/db.sqlite' });

      const result = await badTool.execute({ action: 'schema' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Error');
    });
  });
});
