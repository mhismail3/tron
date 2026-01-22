/**
 * @fileoverview Tests for Session Adapter
 *
 * The session adapter handles session lifecycle including creation,
 * retrieval, resumption, listing, deletion, forking, and model switching.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSessionAdapter } from './session.adapter.js';
import type { EventStoreOrchestrator } from '../../../event-store-orchestrator.js';

describe('SessionAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  const mockSession = {
    sessionId: 'sess-123',
    workingDirectory: '/test/project',
    model: 'claude-sonnet-4-20250514',
    messageCount: 5,
    inputTokens: 1000,
    outputTokens: 500,
    lastTurnInputTokens: 200,
    cacheReadTokens: 300,
    cacheCreationTokens: 100,
    cost: 0.05,
    createdAt: '2024-01-01T00:00:00Z',
    lastActivity: '2024-01-01T01:00:00Z',
    isActive: true,
    lastUserPrompt: 'Hello',
    lastAssistantResponse: 'Hi there!',
  };

  const mockMessages = [
    { role: 'user' as const, content: 'Hello' },
    { role: 'assistant' as const, content: 'Hi there!' },
  ];

  beforeEach(() => {
    mockOrchestrator = {
      createSession: vi.fn(),
      getSession: vi.fn(),
      getSessionMessages: vi.fn(),
      resumeSession: vi.fn(),
      listSessions: vi.fn(),
      endSession: vi.fn(),
      forkSession: vi.fn(),
      switchModel: vi.fn(),
    };
  });

  describe('createSession', () => {
    it('should create a new session and return basic info', async () => {
      vi.mocked(mockOrchestrator.createSession!).mockResolvedValue({
        sessionId: 'new-sess',
        model: 'claude-sonnet-4-20250514',
        createdAt: '2024-01-01T00:00:00Z',
      });

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.createSession({
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });

      expect(mockOrchestrator.createSession).toHaveBeenCalledWith({
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      expect(result).toEqual({
        sessionId: 'new-sess',
        model: 'claude-sonnet-4-20250514',
        createdAt: '2024-01-01T00:00:00Z',
      });
    });
  });

  describe('getSession', () => {
    it('should return session info with messages', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue(mockSession);
      vi.mocked(mockOrchestrator.getSessionMessages!).mockResolvedValue(mockMessages);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getSession('sess-123');

      expect(mockOrchestrator.getSession).toHaveBeenCalledWith('sess-123');
      expect(mockOrchestrator.getSessionMessages).toHaveBeenCalledWith('sess-123');
      expect(result).toMatchObject({
        sessionId: 'sess-123',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
        isActive: true,
      });
      expect(result?.messages).toHaveLength(2);
      expect(result?.messages[0]).toEqual({ role: 'user', content: 'Hello' });
    });

    it('should return null for non-existent session', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue(null);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getSession('non-existent');

      expect(result).toBeNull();
      expect(mockOrchestrator.getSessionMessages).not.toHaveBeenCalled();
    });
  });

  describe('resumeSession', () => {
    it('should resume session and return full info with messages', async () => {
      vi.mocked(mockOrchestrator.resumeSession!).mockResolvedValue(mockSession);
      vi.mocked(mockOrchestrator.getSessionMessages!).mockResolvedValue(mockMessages);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.resumeSession('sess-123');

      expect(mockOrchestrator.resumeSession).toHaveBeenCalledWith('sess-123');
      expect(mockOrchestrator.getSessionMessages).toHaveBeenCalledWith('sess-123');
      expect(result.sessionId).toBe('sess-123');
      expect(result.messages).toHaveLength(2);
    });
  });

  describe('listSessions', () => {
    it('should return list of sessions without full messages', async () => {
      vi.mocked(mockOrchestrator.listSessions!).mockResolvedValue([
        mockSession,
        { ...mockSession, sessionId: 'sess-456' },
      ]);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listSessions({
        workingDirectory: '/test/project',
        limit: 10,
      });

      expect(mockOrchestrator.listSessions).toHaveBeenCalledWith({
        workingDirectory: '/test/project',
        limit: 10,
      });
      expect(result).toHaveLength(2);
      expect(result[0].sessionId).toBe('sess-123');
      expect(result[0].messages).toEqual([]); // Empty for list
      expect(result[1].sessionId).toBe('sess-456');
    });

    it('should handle empty list', async () => {
      vi.mocked(mockOrchestrator.listSessions!).mockResolvedValue([]);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listSessions({});

      expect(result).toEqual([]);
    });
  });

  describe('deleteSession', () => {
    it('should end session and return true', async () => {
      vi.mocked(mockOrchestrator.endSession!).mockResolvedValue(undefined);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.deleteSession('sess-123');

      expect(mockOrchestrator.endSession).toHaveBeenCalledWith('sess-123');
      expect(result).toBe(true);
    });
  });

  describe('forkSession', () => {
    it('should fork session and return fork result', async () => {
      const forkResult = {
        newSessionId: 'forked-sess',
        rootEventId: 'evt-root',
        forkedFromEventId: 'evt-fork-point',
        forkedFromSessionId: 'sess-123',
        worktree: '/test/worktrees/forked',
      };
      vi.mocked(mockOrchestrator.forkSession!).mockResolvedValue(forkResult);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.forkSession('sess-123', 'evt-fork-point');

      expect(mockOrchestrator.forkSession).toHaveBeenCalledWith('sess-123', 'evt-fork-point');
      expect(result).toEqual(forkResult);
    });

    it('should fork session without specific event ID', async () => {
      const forkResult = {
        newSessionId: 'forked-sess',
        rootEventId: 'evt-root',
        forkedFromEventId: 'evt-head',
        forkedFromSessionId: 'sess-123',
        worktree: undefined,
      };
      vi.mocked(mockOrchestrator.forkSession!).mockResolvedValue(forkResult);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.forkSession('sess-123');

      expect(mockOrchestrator.forkSession).toHaveBeenCalledWith('sess-123', undefined);
      expect(result.newSessionId).toBe('forked-sess');
    });
  });

  describe('switchModel', () => {
    it('should delegate model switch to orchestrator', async () => {
      const switchResult = {
        success: true,
        previousModel: 'claude-sonnet-4-20250514',
        newModel: 'claude-opus-4-20250514',
      };
      vi.mocked(mockOrchestrator.switchModel!).mockResolvedValue(switchResult);

      const adapter = createSessionAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.switchModel('sess-123', 'claude-opus-4-20250514');

      expect(mockOrchestrator.switchModel).toHaveBeenCalledWith('sess-123', 'claude-opus-4-20250514');
      expect(result).toEqual(switchResult);
    });
  });
});
