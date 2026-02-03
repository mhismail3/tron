/**
 * @fileoverview Tests for RPC Session Fork Operations
 *
 * These tests verify that the RpcHandler correctly processes
 * fork requests through the session manager interface.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { RpcHandler, type RpcContext } from '../handler.js';
import type { SessionForkResult } from '../types.js';

describe('RpcHandler - Session Fork', () => {
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
        resumeSession: vi.fn().mockResolvedValue({
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
          rootEventId: 'evt_root',
          forkedFromEventId: 'evt_3',
          forkedFromSessionId: 'sess_test',
        } as SessionForkResult),
        switchModel: vi.fn().mockResolvedValue({ success: true }),
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
        rootEventId: 'evt_root',
        forkedFromEventId: 'evt_3',
        forkedFromSessionId: 'sess_test',
      });
      expect(mockContext.sessionManager.forkSession).toHaveBeenCalledWith(
        'sess_test',
        undefined
      );
    });

    it('should fork a session from a specific event', async () => {
      const response = await handler.handle({
        id: 'req_2',
        method: 'session.fork',
        params: { sessionId: 'sess_test', fromEventId: 'evt_2' },
      });

      expect(response.success).toBe(true);
      expect(mockContext.sessionManager.forkSession).toHaveBeenCalledWith(
        'sess_test',
        'evt_2'
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
});

describe('RpcHandler - Cross-Interface Session Continuity', () => {
  it('should enable terminal-to-web session continuation', async () => {
    // This test verifies the user story:
    // 1. Start session in Terminal
    // 2. Fork or continue in Web
    // 3. Handoffs enable context recovery

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
        resumeSession: vi.fn().mockResolvedValue({
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
          rootEventId: 'evt_fork_root',
          forkedFromEventId: 'evt_2',
          forkedFromSessionId: 'sess_terminal',
        }),
        switchModel: vi.fn().mockResolvedValue({ success: true }),
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
      params: { sessionId: 'sess_terminal', fromEventId: 'evt_2' },
    });
    expect(forkResponse.success).toBe(true);
    expect(forkResponse.result).toMatchObject({
      newSessionId: 'sess_web_fork',
      forkedFromSessionId: 'sess_terminal',
    });
  });
});
