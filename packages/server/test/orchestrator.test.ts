/**
 * @fileoverview Tests for Session Orchestrator
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { SessionOrchestrator } from '../src/orchestrator.js';
import { SessionManager, SQLiteMemoryStore } from '@tron/core';

// Mock dependencies
vi.mock('@tron/core', async (importOriginal) => {
  const actual = await importOriginal() as any;
  return {
    ...actual,
    createLogger: () => ({
      info: vi.fn(),
      debug: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
      child: vi.fn(() => ({
        info: vi.fn(),
        debug: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      })),
    }),
    SessionManager: vi.fn().mockImplementation(() => ({
      createSession: vi.fn().mockResolvedValue({
        id: 'sess_test123',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        messages: [],
        createdAt: new Date().toISOString(),
        lastActivityAt: new Date().toISOString(),
        tokenUsage: { inputTokens: 0, outputTokens: 0 },
        currentTurn: 0,
        isActive: true,
        activeFiles: [],
        metadata: {},
      }),
      getSession: vi.fn().mockResolvedValue(null),
      listSessions: vi.fn().mockResolvedValue([]),
      addMessage: vi.fn().mockResolvedValue(undefined),
      endSession: vi.fn().mockResolvedValue(undefined),
      on: vi.fn(),
      emit: vi.fn(),
    })),
    SQLiteMemoryStore: vi.fn().mockImplementation(() => ({
      close: vi.fn().mockResolvedValue(undefined),
      addEntry: vi.fn().mockResolvedValue({ id: 'mem_test' }),
      searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
      getEntry: vi.fn().mockResolvedValue(null),
      deleteEntry: vi.fn().mockResolvedValue(undefined),
    })),
    TronAgent: vi.fn().mockImplementation(() => ({
      run: vi.fn().mockResolvedValue({
        success: true,
        response: { role: 'assistant', content: [{ type: 'text', text: 'Hello' }] },
        toolCalls: [],
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      }),
    })),
  };
});

describe('SessionOrchestrator', () => {
  let orchestrator: SessionOrchestrator;

  beforeEach(async () => {
    vi.clearAllMocks();

    orchestrator = new SessionOrchestrator({
      sessionsDir: '/test/.tron/sessions',
      memoryDbPath: '/test/.tron/memory.db',
      defaultModel: 'claude-sonnet-4-20250514',
      defaultProvider: 'anthropic',
    });

    await orchestrator.initialize();
  });

  afterEach(async () => {
    await orchestrator.shutdown();
  });

  describe('constructor', () => {
    it('should create orchestrator with config', () => {
      expect(orchestrator).toBeInstanceOf(SessionOrchestrator);
    });
  });

  describe('initialize', () => {
    it('should initialize memory store', async () => {
      // Initialize is called in beforeEach
      expect(SQLiteMemoryStore).toHaveBeenCalled();
    });
  });

  describe('getSessionManager', () => {
    it('should return session manager', () => {
      const manager = orchestrator.getSessionManager();
      expect(manager).toBeDefined();
    });
  });

  describe('getMemoryStore', () => {
    it('should return memory store', () => {
      const store = orchestrator.getMemoryStore();
      expect(store).toBeDefined();
    });
  });

  describe('createSession', () => {
    it('should create new session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      expect(session.id).toBe('sess_test123');
      expect(session.workingDirectory).toBe('/test');
    });

    it('should respect max concurrent sessions', async () => {
      const limitedOrchestrator = new SessionOrchestrator({
        sessionsDir: '/test/.tron/sessions',
        memoryDbPath: '/test/.tron/memory.db',
        defaultModel: 'claude-sonnet-4-20250514',
        defaultProvider: 'anthropic',
        maxConcurrentSessions: 1,
      });

      await limitedOrchestrator.initialize();

      // Create first session
      await limitedOrchestrator.createSession({ workingDirectory: '/test1' });

      // Try to create second - should fail
      await expect(
        limitedOrchestrator.createSession({ workingDirectory: '/test2' })
      ).rejects.toThrow('Maximum concurrent sessions');

      await limitedOrchestrator.shutdown();
    });
  });

  describe('resumeSession', () => {
    it('should return already active session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      const resumed = await orchestrator.resumeSession(session.id);
      expect(resumed.id).toBe(session.id);
    });

    it('should throw for non-existent session', async () => {
      await expect(
        orchestrator.resumeSession('sess_nonexistent')
      ).rejects.toThrow('Session not found');
    });
  });

  describe('endSession', () => {
    it('should end active session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      await expect(
        orchestrator.endSession(session.id)
      ).resolves.not.toThrow();
    });
  });

  describe('getSession', () => {
    it('should return active session', async () => {
      const created = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      const session = await orchestrator.getSession(created.id);
      expect(session?.id).toBe(created.id);
    });

    it('should return null for non-existent session', async () => {
      const session = await orchestrator.getSession('sess_nonexistent');
      expect(session).toBeNull();
    });
  });

  describe('listSessions', () => {
    it('should list active sessions', async () => {
      await orchestrator.createSession({ workingDirectory: '/project' });

      const sessions = await orchestrator.listSessions({ activeOnly: true });
      expect(sessions.length).toBe(1);
    });
  });

  describe('getHealth', () => {
    it('should return health status', () => {
      const health = orchestrator.getHealth();

      expect(health.status).toBe('healthy');
      expect(health.activeSessions).toBeGreaterThanOrEqual(0);
      expect(health.uptime).toBeGreaterThan(0);
    });

    it('should track active and processing sessions', async () => {
      await orchestrator.createSession({ workingDirectory: '/project' });

      const health = orchestrator.getHealth();
      expect(health.activeSessions).toBe(1);
      expect(health.processingSessions).toBe(0);
    });
  });

  describe('storeMemory', () => {
    it('should store memory and return ID', async () => {
      const id = await orchestrator.storeMemory({
        workingDirectory: '/project',
        content: 'Test memory',
        type: 'lesson',
      });

      expect(id).toBe('mem_test');
    });
  });

  describe('searchMemory', () => {
    it('should search memories', async () => {
      const results = await orchestrator.searchMemory({
        query: 'test',
        limit: 10,
      });

      expect(results).toEqual([]);
    });
  });
});

describe('SessionOrchestrator - Agent Operations', () => {
  let orchestrator: SessionOrchestrator;

  beforeEach(async () => {
    vi.clearAllMocks();

    orchestrator = new SessionOrchestrator({
      sessionsDir: '/test/.tron/sessions',
      memoryDbPath: '/test/.tron/memory.db',
      defaultModel: 'claude-sonnet-4-20250514',
      defaultProvider: 'anthropic',
    });

    await orchestrator.initialize();
  });

  afterEach(async () => {
    await orchestrator.shutdown();
  });

  describe('runAgent', () => {
    it('should throw for non-active session', async () => {
      await expect(
        orchestrator.runAgent({
          sessionId: 'sess_nonexistent',
          prompt: 'Hello',
        })
      ).rejects.toThrow('Session not active');
    });

    it('should run agent for active session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      const results = await orchestrator.runAgent({
        sessionId: session.id,
        prompt: 'Hello',
      });

      expect(results.length).toBeGreaterThan(0);
    });
  });

  describe('cancelAgent', () => {
    it('should return false for non-processing session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: '/project',
      });

      const result = await orchestrator.cancelAgent(session.id);
      expect(result).toBe(false);
    });
  });
});
