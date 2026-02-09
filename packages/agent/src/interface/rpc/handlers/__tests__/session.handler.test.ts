/**
 * @fileoverview Tests for Session RPC Handlers
 *
 * Tests session.create, session.resume, session.list, session.delete, session.fork handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSessionHandlers } from '../session.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Session Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutSessionManager: RpcContext;
  let mockCreateSession: ReturnType<typeof vi.fn>;
  let mockResumeSession: ReturnType<typeof vi.fn>;
  let mockListSessions: ReturnType<typeof vi.fn>;
  let mockDeleteSession: ReturnType<typeof vi.fn>;
  let mockForkSession: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createSessionHandlers());

    mockCreateSession = vi.fn().mockResolvedValue({
      sessionId: 'sess-new-123',
      workingDirectory: '/projects/myapp',
      model: 'claude-sonnet-4-20250514',
      createdAt: '2024-01-15T10:00:00Z',
    });

    mockResumeSession = vi.fn().mockResolvedValue({
      sessionId: 'sess-123',
      model: 'claude-sonnet-4-20250514',
      messages: [{ role: 'user', content: 'Hello' }],
      lastActivity: '2024-01-15T10:00:00Z',
    });

    mockListSessions = vi.fn().mockResolvedValue([
      {
        sessionId: 'sess-1',
        workingDirectory: '/projects/app1',
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
        inputTokens: 1000,
        outputTokens: 500,
        lastTurnInputTokens: 200,
        cacheReadTokens: 100,
        cacheCreationTokens: 50,
        cost: 0.05,
        createdAt: '2024-01-15T09:00:00Z',
        lastActivity: '2024-01-15T10:00:00Z',
        isActive: true,
        lastUserPrompt: 'Hello',
        lastAssistantResponse: 'Hi there!',
      },
      {
        sessionId: 'sess-2',
        workingDirectory: '/projects/app2',
        model: 'claude-opus-4-20250514',
        messageCount: 10,
        inputTokens: 2000,
        outputTokens: 1000,
        lastTurnInputTokens: 400,
        cacheReadTokens: 200,
        cacheCreationTokens: 100,
        cost: 0.15,
        createdAt: '2024-01-15T08:00:00Z',
        lastActivity: '2024-01-15T11:00:00Z',
        isActive: false,
      },
    ]);

    mockDeleteSession = vi.fn().mockResolvedValue(true);

    mockForkSession = vi.fn().mockResolvedValue({
      newSessionId: 'sess-forked-456',
      fromEventId: 'evt-123',
      messageCount: 3,
    });

    mockContext = {
      sessionManager: {
        createSession: mockCreateSession,
        resumeSession: mockResumeSession,
        listSessions: mockListSessions,
        deleteSession: mockDeleteSession,
        forkSession: mockForkSession,
        getSession: vi.fn(),
        switchModel: vi.fn(),
      } as any,
      agentManager: {} as any,
    };

    mockContextWithoutSessionManager = {
      agentManager: {} as any,
    };
  });

  describe('session.create', () => {
    it('should create a new session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.create',
        params: {
          workingDirectory: '/projects/myapp',
          model: 'claude-sonnet-4-20250514',
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockCreateSession).toHaveBeenCalledWith({
        workingDirectory: '/projects/myapp',
        model: 'claude-sonnet-4-20250514',
      });
      const result = response.result as { sessionId: string };
      expect(result.sessionId).toBe('sess-new-123');
    });

    it('should return error for missing workingDirectory', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.create',
        params: { model: 'claude-sonnet-4-20250514' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('workingDirectory');
    });

    it('should return NOT_AVAILABLE without sessionManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.create',
        params: { workingDirectory: '/projects/myapp' },
      };

      const response = await registry.dispatch(request, mockContextWithoutSessionManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('session.resume', () => {
    it('should resume an existing session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.resume',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockResumeSession).toHaveBeenCalledWith('sess-123');
      const result = response.result as { sessionId: string; messageCount: number };
      expect(result.sessionId).toBe('sess-123');
      expect(result.messageCount).toBe(1);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.resume',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return SESSION_NOT_FOUND for non-existent session', async () => {
      const { SessionError } = await import('@core/utils/errors.js');
      mockResumeSession.mockRejectedValueOnce(
        new SessionError('Session not found: nonexistent', {
          sessionId: 'nonexistent',
          operation: 'resume',
          code: 'SESSION_NOT_FOUND',
        })
      );

      const request: RpcRequest = {
        id: '1',
        method: 'session.resume',
        params: { sessionId: 'nonexistent' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
    });
  });

  describe('session.list', () => {
    it('should list all sessions', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.list',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListSessions).toHaveBeenCalledWith({});
      const result = response.result as { sessions: any[] };
      expect(result.sessions).toHaveLength(2);
    });

    it('should pass filter params', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.list',
        params: { workingDirectory: '/projects/app1' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListSessions).toHaveBeenCalledWith({ workingDirectory: '/projects/app1' });
    });

    it('should map all session fields correctly', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.list',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { sessions: any[] };
      const session = result.sessions[0];
      expect(session.sessionId).toBe('sess-1');
      expect(session.workingDirectory).toBe('/projects/app1');
      expect(session.inputTokens).toBe(1000);
      expect(session.cacheReadTokens).toBe(100);
      expect(session.lastUserPrompt).toBe('Hello');
    });
  });

  describe('session.delete', () => {
    it('should delete a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.delete',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockDeleteSession).toHaveBeenCalledWith('sess-123');
      const result = response.result as { deleted: boolean };
      expect(result.deleted).toBe(true);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.delete',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('session.fork', () => {
    it('should fork a session', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.fork',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockForkSession).toHaveBeenCalledWith('sess-123', undefined);
      const result = response.result as { newSessionId: string };
      expect(result.newSessionId).toBe('sess-forked-456');
    });

    it('should fork from a specific event', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.fork',
        params: { sessionId: 'sess-123', fromEventId: 'evt-456' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockForkSession).toHaveBeenCalledWith('sess-123', 'evt-456');
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'session.fork',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('createSessionHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createSessionHandlers();

      expect(handlers).toHaveLength(5);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('session.create');
      expect(methods).toContain('session.resume');
      expect(methods).toContain('session.list');
      expect(methods).toContain('session.delete');
      expect(methods).toContain('session.fork');
    });

    it('should have correct options for session.create', () => {
      const handlers = createSessionHandlers();
      const createHandler = handlers.find(h => h.method === 'session.create');

      expect(createHandler?.options?.requiredParams).toContain('workingDirectory');
      expect(createHandler?.options?.requiredManagers).toContain('sessionManager');
    });

    it('should have sessionManager as required for all handlers', () => {
      const handlers = createSessionHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('sessionManager');
      }
    });
  });
});
