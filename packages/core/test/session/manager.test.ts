/**
 * @fileoverview Tests for Session Manager
 *
 * TDD: Tests for session lifecycle management
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { SessionManager, type SessionManagerConfig } from '../../src/session/manager.js';
import type { Session, SessionSummary, CreateSessionOptions } from '../../src/session/types.js';

// Mock fs
vi.mock('fs/promises', () => ({
  readFile: vi.fn(),
  writeFile: vi.fn(),
  appendFile: vi.fn(),
  mkdir: vi.fn(),
  readdir: vi.fn(),
  stat: vi.fn(),
  unlink: vi.fn(),
  rm: vi.fn(),
  access: vi.fn(),
}));

describe('SessionManager', () => {
  let manager: SessionManager;
  let config: SessionManagerConfig;

  beforeEach(() => {
    vi.clearAllMocks();

    config = {
      sessionsDir: '/test/.tron/sessions',
      defaultModel: 'claude-sonnet-4-20250514',
      defaultProvider: 'anthropic',
    };

    manager = new SessionManager(config);

    // Default mock implementations
    vi.mocked(fs.mkdir).mockResolvedValue(undefined);
    vi.mocked(fs.writeFile).mockResolvedValue();
    vi.mocked(fs.appendFile).mockResolvedValue();
    vi.mocked(fs.readdir).mockResolvedValue([]);
    vi.mocked(fs.access).mockRejectedValue(new Error('Not found'));
  });

  describe('constructor', () => {
    it('should create manager with config', () => {
      expect(manager).toBeInstanceOf(SessionManager);
    });
  });

  describe('createSession', () => {
    it('should create new session with unique ID', async () => {
      const options: CreateSessionOptions = {
        workingDirectory: '/home/user/project',
      };

      const session = await manager.createSession(options);

      expect(session.id).toMatch(/^sess_/);
      expect(session.workingDirectory).toBe('/home/user/project');
      expect(session.model).toBe('claude-sonnet-4-20250514');
      expect(session.isActive).toBe(true);
    });

    it('should use provided model and provider', async () => {
      const session = await manager.createSession({
        workingDirectory: '/test',
        model: 'claude-opus-4-5-20251101',
        provider: 'anthropic',
      });

      expect(session.model).toBe('claude-opus-4-5-20251101');
      expect(session.provider).toBe('anthropic');
    });

    it('should create session directory and file', async () => {
      await manager.createSession({
        workingDirectory: '/test',
      });

      expect(fs.mkdir).toHaveBeenCalled();
      expect(fs.appendFile).toHaveBeenCalled();
    });

    it('should write session_start entry to JSONL', async () => {
      await manager.createSession({
        workingDirectory: '/test',
        title: 'Test Session',
        tags: ['test'],
      });

      const appendCall = vi.mocked(fs.appendFile).mock.calls[0];
      const entry = JSON.parse(appendCall[1] as string);

      expect(entry.type).toBe('session_start');
      expect(entry.workingDirectory).toBe('/test');
      expect(entry.metadata.title).toBe('Test Session');
    });

    it('should emit session_created event', async () => {
      const listener = vi.fn();
      manager.on('session_created', listener);

      await manager.createSession({ workingDirectory: '/test' });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          workingDirectory: '/test',
        })
      );
    });
  });

  describe('getSession', () => {
    it('should return session by ID', async () => {
      // First create a session
      const created = await manager.createSession({ workingDirectory: '/test' });

      // Then get it
      const session = await manager.getSession(created.id);

      expect(session).not.toBeNull();
      expect(session?.id).toBe(created.id);
    });

    it('should return null for non-existent session', async () => {
      const session = await manager.getSession('sess_nonexistent');

      expect(session).toBeNull();
    });

    it('should load session from JSONL file', async () => {
      const sessionId = 'sess_existing';
      const jsonlContent = [
        JSON.stringify({
          type: 'session_start',
          timestamp: '2025-01-01T00:00:00Z',
          sessionId,
          workingDirectory: '/test',
          model: 'claude-sonnet-4-20250514',
          provider: 'anthropic',
          metadata: {},
        }),
        JSON.stringify({
          type: 'message',
          timestamp: '2025-01-01T00:01:00Z',
          message: { role: 'user', content: 'Hello' },
        }),
      ].join('\n');

      vi.mocked(fs.access).mockResolvedValueOnce(undefined);
      vi.mocked(fs.readFile).mockResolvedValueOnce(jsonlContent);

      const session = await manager.getSession(sessionId);

      expect(session).not.toBeNull();
      expect(session?.messages.length).toBe(1);
    });
  });

  describe('listSessions', () => {
    beforeEach(() => {
      // Setup existing sessions
      vi.mocked(fs.readdir).mockResolvedValue([
        { name: 'sess_1.jsonl', isFile: () => true, isDirectory: () => false },
        { name: 'sess_2.jsonl', isFile: () => true, isDirectory: () => false },
      ] as any);

      // Mock reading session files
      vi.mocked(fs.readFile)
        .mockResolvedValueOnce(JSON.stringify({
          type: 'session_start',
          sessionId: 'sess_1',
          workingDirectory: '/project1',
          model: 'claude-sonnet-4-20250514',
          provider: 'anthropic',
          timestamp: '2025-01-01T00:00:00Z',
          metadata: { title: 'Session 1' },
        }))
        .mockResolvedValueOnce(JSON.stringify({
          type: 'session_start',
          sessionId: 'sess_2',
          workingDirectory: '/project2',
          model: 'claude-sonnet-4-20250514',
          provider: 'anthropic',
          timestamp: '2025-01-02T00:00:00Z',
          metadata: { title: 'Session 2' },
        }));
    });

    it('should list all sessions', async () => {
      const sessions = await manager.listSessions({});

      expect(sessions.length).toBe(2);
    });

    it('should filter by working directory', async () => {
      const sessions = await manager.listSessions({
        workingDirectory: '/project1',
      });

      expect(sessions.every(s => s.workingDirectory === '/project1')).toBe(true);
    });

    it('should limit results', async () => {
      const sessions = await manager.listSessions({ limit: 1 });

      expect(sessions.length).toBeLessThanOrEqual(1);
    });

    it('should order by creation date', async () => {
      const sessions = await manager.listSessions({
        orderBy: 'createdAt',
        order: 'desc',
      });

      expect(sessions.length).toBeGreaterThan(0);
    });
  });

  describe('addMessage', () => {
    it('should append message to session', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });

      await manager.addMessage(session.id, {
        role: 'user',
        content: 'Hello',
      });

      expect(fs.appendFile).toHaveBeenCalledWith(
        expect.stringContaining(session.id),
        expect.stringContaining('"role":"user"'),
      );
    });

    it('should update lastActivityAt', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });
      const originalLastActivity = session.lastActivityAt;

      // Wait a bit
      await new Promise(r => setTimeout(r, 10));

      await manager.addMessage(session.id, {
        role: 'user',
        content: 'Hello',
      });

      const updated = await manager.getSession(session.id);
      expect(updated?.lastActivityAt).not.toBe(originalLastActivity);
    });
  });

  describe('endSession', () => {
    it('should mark session as ended', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });

      await manager.endSession(session.id, 'completed');

      const entry = vi.mocked(fs.appendFile).mock.calls.find(
        call => (call[1] as string).includes('"type":"session_end"')
      );
      expect(entry).toBeDefined();
    });

    it('should emit session_ended event', async () => {
      const listener = vi.fn();
      manager.on('session_ended', listener);

      const session = await manager.createSession({ workingDirectory: '/test' });
      await manager.endSession(session.id, 'completed');

      expect(listener).toHaveBeenCalledWith({
        sessionId: session.id,
        reason: 'completed',
      });
    });

    it('should include summary if provided', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });

      await manager.endSession(session.id, 'completed', 'Implemented feature X');

      const entry = vi.mocked(fs.appendFile).mock.calls.find(
        call => (call[1] as string).includes('"summary":"Implemented feature X"')
      );
      expect(entry).toBeDefined();
    });
  });

  describe('deleteSession', () => {
    it('should delete session file', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });
      vi.mocked(fs.rm).mockResolvedValue();

      await manager.deleteSession(session.id);

      expect(fs.rm).toHaveBeenCalledWith(
        expect.stringContaining(session.id),
        expect.any(Object)
      );
    });

    it('should emit session_deleted event', async () => {
      const listener = vi.fn();
      manager.on('session_deleted', listener);

      const session = await manager.createSession({ workingDirectory: '/test' });
      vi.mocked(fs.rm).mockResolvedValue();

      await manager.deleteSession(session.id);

      expect(listener).toHaveBeenCalledWith({ sessionId: session.id });
    });

    it('should return false if session not found', async () => {
      vi.mocked(fs.rm).mockRejectedValue(new Error('ENOENT'));

      const result = await manager.deleteSession('sess_nonexistent');

      expect(result).toBe(false);
    });
  });

  describe('forkSession', () => {
    it('should create new session with copied messages', async () => {
      const original = await manager.createSession({ workingDirectory: '/test' });
      await manager.addMessage(original.id, { role: 'user', content: 'Hello' });

      const result = await manager.forkSession({
        sessionId: original.id,
      });

      expect(result.newSessionId).toMatch(/^sess_/);
      expect(result.forkedFrom).toBe(original.id);
    });

    it('should fork from specific index', async () => {
      const original = await manager.createSession({ workingDirectory: '/test' });
      await manager.addMessage(original.id, { role: 'user', content: 'Message 1' });
      await manager.addMessage(original.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 1' }] });
      await manager.addMessage(original.id, { role: 'user', content: 'Message 2' });

      const result = await manager.forkSession({
        sessionId: original.id,
        fromIndex: 1, // Fork after first user message
      });

      expect(result.messageCount).toBeLessThanOrEqual(2);
    });

    it('should set parent metadata', async () => {
      const original = await manager.createSession({ workingDirectory: '/test' });

      const result = await manager.forkSession({
        sessionId: original.id,
        title: 'Forked Session',
      });

      const forked = await manager.getSession(result.newSessionId);
      expect(forked?.metadata.parentSessionId).toBe(original.id);
    });

    it('should emit session_forked event', async () => {
      const listener = vi.fn();
      manager.on('session_forked', listener);

      const original = await manager.createSession({ workingDirectory: '/test' });
      const result = await manager.forkSession({ sessionId: original.id });

      expect(listener).toHaveBeenCalledWith({
        original: original.id,
        forked: result.newSessionId,
      });
    });
  });

  describe('rewindSession', () => {
    it('should remove messages after index', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });
      await manager.addMessage(session.id, { role: 'user', content: 'M1' });
      await manager.addMessage(session.id, { role: 'assistant', content: [{ type: 'text', text: 'R1' }] });
      await manager.addMessage(session.id, { role: 'user', content: 'M2' });

      const result = await manager.rewindSession({
        sessionId: session.id,
        toIndex: 1,
      });

      expect(result.newMessageCount).toBe(2);
      expect(result.removedCount).toBe(1);
    });

    it('should emit session_rewound event', async () => {
      const listener = vi.fn();
      manager.on('session_rewound', listener);

      const session = await manager.createSession({ workingDirectory: '/test' });
      await manager.addMessage(session.id, { role: 'user', content: 'M1' });

      await manager.rewindSession({
        sessionId: session.id,
        toIndex: 0,
      });

      expect(listener).toHaveBeenCalledWith({
        sessionId: session.id,
        toIndex: 0,
      });
    });

    it('should throw if index out of bounds', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });
      await manager.addMessage(session.id, { role: 'user', content: 'M1' });

      await expect(
        manager.rewindSession({
          sessionId: session.id,
          toIndex: 100,
        })
      ).rejects.toThrow('Index out of bounds');
    });
  });

  describe('updateMetadata', () => {
    it('should update session metadata', async () => {
      const session = await manager.createSession({ workingDirectory: '/test' });

      await manager.updateMetadata(session.id, {
        title: 'Updated Title',
        tags: ['updated'],
      });

      const entry = vi.mocked(fs.appendFile).mock.calls.find(
        call => (call[1] as string).includes('"type":"metadata_update"')
      );
      expect(entry).toBeDefined();
    });
  });

  describe('getMostRecent', () => {
    it('should return most recently active session', async () => {
      const s1 = await manager.createSession({ workingDirectory: '/test1' });
      await new Promise(r => setTimeout(r, 10));
      const s2 = await manager.createSession({ workingDirectory: '/test2' });

      const recent = await manager.getMostRecent('/test2');

      expect(recent?.id).toBe(s2.id);
    });

    it('should filter by working directory', async () => {
      await manager.createSession({ workingDirectory: '/test1' });
      const s2 = await manager.createSession({ workingDirectory: '/test2' });

      const recent = await manager.getMostRecent('/test2');

      expect(recent?.id).toBe(s2.id);
    });

    it('should return null if no sessions', async () => {
      const recent = await manager.getMostRecent('/nonexistent');

      expect(recent).toBeNull();
    });
  });
});
