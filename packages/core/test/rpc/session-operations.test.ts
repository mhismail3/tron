/**
 * @fileoverview Tests for RPC Session Fork/Rewind Operations
 *
 * These tests verify that the RpcHandler correctly processes
 * fork and rewind requests through the session manager interface.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { RpcHandler, type RpcContext } from '../../src/rpc/handler.js';
import type { SessionForkResult, SessionRewindResult } from '../../src/rpc/types.js';

describe('RpcHandler - Session Fork & Rewind', () => {
  let handler: RpcHandler;
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      sessionManager: {
        createSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_test',
          model: 'claude-sonnet-4-20250514',
          createdAt: new Date().toISOString(),
        }),
        getSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_test',
          workingDirectory: '/test',
          model: 'claude-sonnet-4-20250514',
          messageCount: 5,
          createdAt: new Date().toISOString(),
          lastActivity: new Date().toISOString(),
          isActive: true,
          messages: [
            { role: 'user', content: 'msg1' },
            { role: 'assistant', content: 'resp1' },
            { role: 'user', content: 'msg2' },
            { role: 'assistant', content: 'resp2' },
            { role: 'user', content: 'msg3' },
          ],
        }),
        listSessions: vi.fn().mockResolvedValue([]),
        deleteSession: vi.fn().mockResolvedValue(true),
        forkSession: vi.fn().mockResolvedValue({
          newSessionId: 'sess_fork',
          forkedFrom: 'sess_test',
          messageCount: 3,
        } as SessionForkResult),
        rewindSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_test',
          newMessageCount: 2,
          removedCount: 3,
        } as SessionRewindResult),
      },
      agentManager: {
        prompt: vi.fn().mockResolvedValue({ acknowledged: true }),
        abort: vi.fn().mockResolvedValue({ aborted: true }),
        getState: vi.fn().mockResolvedValue({
          isRunning: false,
          currentTurn: 0,
          messageCount: 0,
          tokenUsage: { input: 0, output: 0 },
          model: 'claude-sonnet-4-20250514',
          tools: [],
        }),
      },
      memoryStore: {
        searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
        addEntry: vi.fn().mockResolvedValue({ id: 'mem_1' }),
        listHandoffs: vi.fn().mockResolvedValue([]),
      },
    };

    handler = new RpcHandler(mockContext);
  });

  describe('session.fork', () => {
    it('should fork a session with all messages', async () => {
      const response = await handler.handle({
        id: 'req_1',
        method: 'session.fork',
        params: { sessionId: 'sess_test' },
      });

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        newSessionId: 'sess_fork',
        forkedFrom: 'sess_test',
        messageCount: 3,
      });
      expect(mockContext.sessionManager.forkSession).toHaveBeenCalledWith(
        'sess_test',
        undefined
      );
    });

    it('should fork a session from a specific index', async () => {
      const response = await handler.handle({
        id: 'req_2',
        method: 'session.fork',
        params: { sessionId: 'sess_test', fromMessageIndex: 2 },
      });

      expect(response.success).toBe(true);
      expect(mockContext.sessionManager.forkSession).toHaveBeenCalledWith(
        'sess_test',
        2
      );
    });

    it('should require sessionId', async () => {
      const response = await handler.handle({
        id: 'req_3',
        method: 'session.fork',
        params: {},
      });

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('session.rewind', () => {
    it('should rewind a session to a specific index', async () => {
      const response = await handler.handle({
        id: 'req_4',
        method: 'session.rewind',
        params: { sessionId: 'sess_test', toMessageIndex: 1 },
      });

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        sessionId: 'sess_test',
        newMessageCount: 2,
        removedCount: 3,
      });
      expect(mockContext.sessionManager.rewindSession).toHaveBeenCalledWith(
        'sess_test',
        1
      );
    });

    it('should require sessionId', async () => {
      const response = await handler.handle({
        id: 'req_5',
        method: 'session.rewind',
        params: { toMessageIndex: 1 },
      });

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should require toMessageIndex', async () => {
      const response = await handler.handle({
        id: 'req_6',
        method: 'session.rewind',
        params: { sessionId: 'sess_test' },
      });

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('memory.getHandoffs', () => {
    it('should list handoffs', async () => {
      (mockContext.memoryStore.listHandoffs as any).mockResolvedValue([
        {
          id: 'handoff_1',
          sessionId: 'sess_1',
          summary: 'First handoff',
          createdAt: '2024-01-01T00:00:00Z',
        },
        {
          id: 'handoff_2',
          sessionId: 'sess_2',
          summary: 'Second handoff',
          createdAt: '2024-01-02T00:00:00Z',
        },
      ]);

      const response = await handler.handle({
        id: 'req_7',
        method: 'memory.getHandoffs',
        params: { limit: 10 },
      });

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        handoffs: [
          { id: 'handoff_1', sessionId: 'sess_1', summary: 'First handoff', createdAt: '2024-01-01T00:00:00Z' },
          { id: 'handoff_2', sessionId: 'sess_2', summary: 'Second handoff', createdAt: '2024-01-02T00:00:00Z' },
        ],
      });
    });

    it('should filter by working directory', async () => {
      const response = await handler.handle({
        id: 'req_8',
        method: 'memory.getHandoffs',
        params: { workingDirectory: '/project', limit: 5 },
      });

      expect(response.success).toBe(true);
      expect(mockContext.memoryStore.listHandoffs).toHaveBeenCalledWith('/project', 5);
    });
  });
});

describe('RpcHandler - Cross-Interface Session Continuity', () => {
  it('should enable terminal-to-web session continuation', async () => {
    // This test verifies the user story:
    // 1. Start session in Terminal
    // 2. Fork or continue in Web
    // 3. Rewind if needed
    // 4. Handoffs enable context recovery

    const mockContext: RpcContext = {
      sessionManager: {
        createSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_terminal',
          model: 'claude-sonnet-4-20250514',
          createdAt: new Date().toISOString(),
        }),
        getSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_terminal',
          workingDirectory: '/project',
          model: 'claude-sonnet-4-20250514',
          messageCount: 4,
          createdAt: new Date().toISOString(),
          lastActivity: new Date().toISOString(),
          isActive: true,
          messages: [
            { role: 'user', content: 'Start implementation' },
            { role: 'assistant', content: 'Created initial files' },
            { role: 'user', content: 'Add tests' },
            { role: 'assistant', content: 'Tests added, some failing' },
          ],
        }),
        listSessions: vi.fn().mockResolvedValue([]),
        deleteSession: vi.fn().mockResolvedValue(true),
        forkSession: vi.fn().mockResolvedValue({
          newSessionId: 'sess_web_fork',
          forkedFrom: 'sess_terminal',
          messageCount: 2,
        }),
        rewindSession: vi.fn().mockResolvedValue({
          sessionId: 'sess_terminal',
          newMessageCount: 2,
          removedCount: 2,
        }),
      },
      agentManager: {
        prompt: vi.fn().mockResolvedValue({ acknowledged: true }),
        abort: vi.fn().mockResolvedValue({ aborted: true }),
        getState: vi.fn().mockResolvedValue({
          isRunning: false,
          currentTurn: 0,
          messageCount: 0,
          tokenUsage: { input: 0, output: 0 },
          model: 'claude-sonnet-4-20250514',
          tools: [],
        }),
      },
      memoryStore: {
        searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
        addEntry: vi.fn().mockResolvedValue({ id: 'mem_1' }),
        listHandoffs: vi.fn().mockResolvedValue([
          {
            id: 'handoff_1',
            sessionId: 'sess_terminal',
            summary: 'Initial implementation with failing tests',
            createdAt: new Date().toISOString(),
          },
        ]),
      },
    };

    const handler = new RpcHandler(mockContext);

    // Step 1: Resume terminal session from web
    const resumeResponse = await handler.handle({
      id: 'resume_1',
      method: 'session.resume',
      params: { sessionId: 'sess_terminal' },
    });
    expect(resumeResponse.success).toBe(true);
    expect(resumeResponse.result).toMatchObject({
      sessionId: 'sess_terminal',
      messageCount: 4,
    });

    // Step 2: Fork to try different approach
    const forkResponse = await handler.handle({
      id: 'fork_1',
      method: 'session.fork',
      params: { sessionId: 'sess_terminal', fromMessageIndex: 2 },
    });
    expect(forkResponse.success).toBe(true);
    expect(forkResponse.result).toMatchObject({
      newSessionId: 'sess_web_fork',
      forkedFrom: 'sess_terminal',
    });

    // Step 3: Rewind original after bad approach
    const rewindResponse = await handler.handle({
      id: 'rewind_1',
      method: 'session.rewind',
      params: { sessionId: 'sess_terminal', toMessageIndex: 1 },
    });
    expect(rewindResponse.success).toBe(true);
    expect(rewindResponse.result).toMatchObject({
      sessionId: 'sess_terminal',
      removedCount: 2,
    });

    // Step 4: Get handoffs for context
    const handoffsResponse = await handler.handle({
      id: 'handoffs_1',
      method: 'memory.getHandoffs',
      params: {},
    });
    expect(handoffsResponse.success).toBe(true);
  });
});
