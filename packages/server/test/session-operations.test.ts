/**
 * @fileoverview Tests for Session Fork/Rewind/Handoff Operations
 *
 * These tests verify the critical cross-interface session management features
 * that enable users to start sessions in one interface (Terminal, Web, App)
 * and continue, fork, or rewind them in another.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { SessionOrchestrator } from '../src/orchestrator.js';
import type { Session } from '@tron/core';

// Mock dependencies
vi.mock('@tron/core', async (importOriginal) => {
  const actual = (await importOriginal()) as any;
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
    SessionManager: vi.fn().mockImplementation(() => {
      const sessions = new Map<string, Session>();
      let sessionCounter = 0;

      return {
        createSession: vi.fn().mockImplementation(async (options) => {
          sessionCounter++;
          const session: Session = {
            id: `sess_test${sessionCounter}`,
            workingDirectory: options.workingDirectory ?? '/test',
            model: options.model ?? 'claude-sonnet-4-20250514',
            provider: options.provider ?? 'anthropic',
            messages: [],
            createdAt: new Date().toISOString(),
            lastActivityAt: new Date().toISOString(),
            tokenUsage: { inputTokens: 0, outputTokens: 0 },
            currentTurn: 0,
            isActive: true,
            activeFiles: [],
            metadata: {},
          };
          sessions.set(session.id, session);
          return session;
        }),
        getSession: vi.fn().mockImplementation(async (sessionId: string) => {
          return sessions.get(sessionId) ?? null;
        }),
        listSessions: vi.fn().mockResolvedValue([]),
        addMessage: vi.fn().mockImplementation(async (sessionId: string, message: unknown) => {
          const session = sessions.get(sessionId);
          if (session) {
            session.messages.push(message as any);
          }
        }),
        endSession: vi.fn().mockResolvedValue(undefined),
        forkSession: vi.fn().mockImplementation(async (options) => {
          const original = sessions.get(options.sessionId);
          if (!original) throw new Error('Session not found');

          sessionCounter++;
          const fromIndex = options.fromIndex ?? original.messages.length;
          const newSession: Session = {
            id: `sess_fork${sessionCounter}`,
            workingDirectory: original.workingDirectory,
            model: original.model,
            provider: original.provider,
            messages: original.messages.slice(0, fromIndex),
            createdAt: new Date().toISOString(),
            lastActivityAt: new Date().toISOString(),
            tokenUsage: { inputTokens: 0, outputTokens: 0 },
            currentTurn: 0,
            isActive: true,
            activeFiles: [],
            metadata: { parentSessionId: original.id },
          };
          sessions.set(newSession.id, newSession);

          return {
            newSessionId: newSession.id,
            forkedFrom: original.id,
            messageCount: newSession.messages.length,
          };
        }),
        rewindSession: vi.fn().mockImplementation(async (options) => {
          const session = sessions.get(options.sessionId);
          if (!session) throw new Error('Session not found');

          const toIndex = options.toIndex;
          if (toIndex < 0 || toIndex >= session.messages.length) {
            throw new Error('Index out of bounds');
          }

          const removedCount = session.messages.length - (toIndex + 1);
          session.messages = session.messages.slice(0, toIndex + 1);

          return {
            sessionId: session.id,
            newMessageCount: session.messages.length,
            removedCount,
          };
        }),
        updateMetadata: vi.fn().mockResolvedValue(undefined),
        on: vi.fn(),
        emit: vi.fn(),
      };
    }),
    SQLiteMemoryStore: vi.fn().mockImplementation(() => ({
      close: vi.fn().mockResolvedValue(undefined),
      addEntry: vi.fn().mockResolvedValue({ id: 'mem_test' }),
      searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
      getEntry: vi.fn().mockResolvedValue(null),
      deleteEntry: vi.fn().mockResolvedValue(undefined),
    })),
    HandoffManager: vi.fn().mockImplementation(() => {
      const handoffs: any[] = [];
      let handoffCounter = 0;

      return {
        initialize: vi.fn().mockResolvedValue(undefined),
        create: vi.fn().mockImplementation(async (handoff) => {
          handoffCounter++;
          const id = `handoff_${handoffCounter}`;
          handoffs.push({
            id,
            sessionId: handoff.sessionId,
            timestamp: handoff.timestamp,
            summary: handoff.summary,
            codeChanges: handoff.codeChanges ?? [],
            currentState: handoff.currentState ?? '',
            blockers: handoff.blockers ?? [],
            nextSteps: handoff.nextSteps ?? [],
            patterns: handoff.patterns ?? [],
          });
          return id;
        }),
        get: vi.fn().mockImplementation(async (id: string) => {
          return handoffs.find((h) => h.id === id) ?? null;
        }),
        getRecent: vi.fn().mockImplementation(async (limit = 5) => {
          return handoffs.slice(-limit).reverse();
        }),
        getBySession: vi.fn().mockImplementation(async (sessionId: string) => {
          return handoffs.filter((h) => h.sessionId === sessionId);
        }),
        search: vi.fn().mockImplementation(async (query: string, limit = 10) => {
          return handoffs
            .filter((h) => h.summary.toLowerCase().includes(query.toLowerCase()))
            .slice(0, limit);
        }),
        close: vi.fn().mockResolvedValue(undefined),
      };
    }),
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

describe('SessionOrchestrator - Fork Operations', () => {
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

  it('should fork a session with all messages', async () => {
    // Create original session
    const original = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    // Add some messages
    const sessionManager = orchestrator.getSessionManager();
    await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 1' });
    await sessionManager.addMessage(original.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 1' }] });
    await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 2' });

    // Fork the session
    const result = await orchestrator.forkSession(original.id);

    expect(result.newSessionId).toBeDefined();
    expect(result.newSessionId).not.toBe(original.id);
    expect(result.forkedFrom).toBe(original.id);
    expect(result.messageCount).toBe(3);
  });

  it('should fork a session from a specific index', async () => {
    const original = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    const sessionManager = orchestrator.getSessionManager();
    await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 1' });
    await sessionManager.addMessage(original.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 1' }] });
    await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 2' });
    await sessionManager.addMessage(original.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 2' }] });

    // Fork from index 2 (only first 2 messages)
    const result = await orchestrator.forkSession(original.id, 2);

    expect(result.messageCount).toBe(2);
  });

  it('should throw when forking non-existent session', async () => {
    await expect(orchestrator.forkSession('sess_nonexistent')).rejects.toThrow('Session not found');
  });
});

describe('SessionOrchestrator - Rewind Operations', () => {
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

  it('should rewind a session to a specific index', async () => {
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    const sessionManager = orchestrator.getSessionManager();
    await sessionManager.addMessage(session.id, { role: 'user', content: 'Message 1' });
    await sessionManager.addMessage(session.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 1' }] });
    await sessionManager.addMessage(session.id, { role: 'user', content: 'Message 2' });
    await sessionManager.addMessage(session.id, { role: 'assistant', content: [{ type: 'text', text: 'Response 2' }] });

    // Rewind to index 1 (keep first 2 messages)
    const result = await orchestrator.rewindSession(session.id, 1);

    expect(result.sessionId).toBe(session.id);
    expect(result.newMessageCount).toBe(2);
    expect(result.removedCount).toBe(2);
  });

  it('should throw when rewinding non-existent session', async () => {
    await expect(orchestrator.rewindSession('sess_nonexistent', 0)).rejects.toThrow('Session not found');
  });

  it('should throw when rewinding to invalid index', async () => {
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    const sessionManager = orchestrator.getSessionManager();
    await sessionManager.addMessage(session.id, { role: 'user', content: 'Message 1' });

    // Rewind to negative index should fail
    await expect(orchestrator.rewindSession(session.id, -1)).rejects.toThrow('Index out of bounds');

    // Rewind beyond messages should fail
    await expect(orchestrator.rewindSession(session.id, 10)).rejects.toThrow('Index out of bounds');
  });
});

describe('SessionOrchestrator - Handoff Operations', () => {
  let orchestrator: SessionOrchestrator;

  beforeEach(async () => {
    vi.clearAllMocks();
    orchestrator = new SessionOrchestrator({
      sessionsDir: '/test/.tron/sessions',
      memoryDbPath: '/test/.tron/memory.db',
      handoffDbPath: '/test/.tron/handoffs.db',
      defaultModel: 'claude-sonnet-4-20250514',
      defaultProvider: 'anthropic',
    });
    await orchestrator.initialize();
  });

  afterEach(async () => {
    await orchestrator.shutdown();
  });

  it('should create a handoff for a session', async () => {
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    const handoffId = await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'Implemented feature X',
      codeChanges: [{ file: 'src/feature.ts', description: 'Added new feature' }],
      currentState: 'Feature complete, tests passing',
      nextSteps: ['Add documentation', 'Deploy to staging'],
      blockers: [],
      patterns: ['TDD', 'Clean architecture'],
    });

    expect(handoffId).toBeDefined();
    expect(handoffId).toMatch(/^handoff_/);
  });

  it('should list recent handoffs', async () => {
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'First handoff',
      codeChanges: [],
      currentState: 'Initial',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'Second handoff',
      codeChanges: [],
      currentState: 'Progress',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    const handoffs = await orchestrator.listHandoffs(5);

    expect(handoffs.length).toBe(2);
  });

  it('should get handoffs for a specific session', async () => {
    const session1 = await orchestrator.createSession({
      workingDirectory: '/project1',
    });

    const session2 = await orchestrator.createSession({
      workingDirectory: '/project2',
    });

    await orchestrator.createHandoff({
      sessionId: session1.id,
      summary: 'Session 1 handoff',
      codeChanges: [],
      currentState: '',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    await orchestrator.createHandoff({
      sessionId: session2.id,
      summary: 'Session 2 handoff',
      codeChanges: [],
      currentState: '',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    const session1Handoffs = await orchestrator.getSessionHandoffs(session1.id);

    expect(session1Handoffs.length).toBe(1);
    expect(session1Handoffs[0].summary).toBe('Session 1 handoff');
  });

  it('should search handoffs', async () => {
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
    });

    await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'Authentication feature complete',
      codeChanges: [],
      currentState: '',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'Database migration done',
      codeChanges: [],
      currentState: '',
      nextSteps: [],
      blockers: [],
      patterns: [],
    });

    const results = await orchestrator.searchHandoffs('authentication', 10);

    expect(results.length).toBe(1);
    expect(results[0].summary).toContain('Authentication');
  });
});

describe('RpcContext Integration', () => {
  let orchestrator: SessionOrchestrator;

  beforeEach(async () => {
    vi.clearAllMocks();
    orchestrator = new SessionOrchestrator({
      sessionsDir: '/test/.tron/sessions',
      memoryDbPath: '/test/.tron/memory.db',
      handoffDbPath: '/test/.tron/handoffs.db',
      defaultModel: 'claude-sonnet-4-20250514',
      defaultProvider: 'anthropic',
    });
    await orchestrator.initialize();
  });

  afterEach(async () => {
    await orchestrator.shutdown();
  });

  it('should expose forkSession for RPC', async () => {
    expect(orchestrator.forkSession).toBeDefined();
    expect(typeof orchestrator.forkSession).toBe('function');
  });

  it('should expose rewindSession for RPC', async () => {
    expect(orchestrator.rewindSession).toBeDefined();
    expect(typeof orchestrator.rewindSession).toBe('function');
  });

  it('should expose listHandoffs for RPC', async () => {
    expect(orchestrator.listHandoffs).toBeDefined();
    expect(typeof orchestrator.listHandoffs).toBe('function');
  });

  it('should provide cross-interface session continuity', async () => {
    // Simulate: Start in Terminal
    const session = await orchestrator.createSession({
      workingDirectory: '/project',
      title: 'Started in Terminal',
    });

    const sessionManager = orchestrator.getSessionManager();
    await sessionManager.addMessage(session.id, { role: 'user', content: 'Initial work' });
    await sessionManager.addMessage(session.id, {
      role: 'assistant',
      content: [{ type: 'text', text: 'Done some work' }],
    });

    // Create handoff for context transfer
    await orchestrator.createHandoff({
      sessionId: session.id,
      summary: 'Started implementing feature X in terminal',
      codeChanges: [{ file: 'src/feature.ts', description: 'Initial scaffold' }],
      currentState: 'Basic structure in place',
      nextSteps: ['Add tests', 'Implement core logic'],
      blockers: [],
      patterns: [],
    });

    // Simulate: Continue in Web (same session)
    const retrieved = await orchestrator.getSession(session.id);
    expect(retrieved).not.toBeNull();
    expect(retrieved?.messages.length).toBe(2);

    // Simulate: Fork for different approach
    const forkResult = await orchestrator.forkSession(session.id, 1);
    expect(forkResult.messageCount).toBe(1); // Only first message

    // Simulate: Rewind after mistake
    await sessionManager.addMessage(session.id, { role: 'user', content: 'Bad approach' });
    await sessionManager.addMessage(session.id, {
      role: 'assistant',
      content: [{ type: 'text', text: 'This was wrong' }],
    });

    const rewindResult = await orchestrator.rewindSession(session.id, 1);
    expect(rewindResult.removedCount).toBe(2);

    // Verify handoffs are accessible across interfaces
    const handoffs = await orchestrator.listHandoffs(10);
    expect(handoffs.length).toBeGreaterThan(0);
  });
});
