/**
 * @fileoverview Tests for HTTP API
 *
 * TDD tests for the REST API endpoints.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  HttpApi,
  createHttpApi,
  type HttpApiConfig,
  type HttpApiContext,
} from '../api.js';

// Mock context
const createMockContext = (): HttpApiContext => ({
  createSession: vi.fn().mockResolvedValue({
    sessionId: 'session-123',
    workspaceId: 'workspace-1',
  }),
  getSessionState: vi.fn().mockResolvedValue({
    isRunning: false,
    currentTurn: 0,
    messageCount: 0,
    tokenUsage: { input: 0, output: 0 },
    model: 'claude-sonnet-4-20250514',
    tools: [],
    wasInterrupted: false,
  }),
  sendPrompt: vi.fn().mockResolvedValue({
    acknowledged: true,
    runId: 'run_abc123',
  }),
  abortSession: vi.fn().mockResolvedValue({ aborted: true }),
  listSessions: vi.fn().mockResolvedValue({
    sessions: [
      { sessionId: 'session-1', status: 'active' },
      { sessionId: 'session-2', status: 'active' },
    ],
  }),
});

describe('HttpApi', () => {
  let api: HttpApi;
  let mockContext: HttpApiContext;
  const config: HttpApiConfig = {
    basePath: '/api',
    enableCors: true,
  };

  beforeEach(() => {
    mockContext = createMockContext();
    api = createHttpApi(config, mockContext);
  });

  describe('handleRequest', () => {
    it('should return 404 for unknown paths', async () => {
      const response = await api.handleRequest('GET', '/api/unknown', {});

      expect(response.status).toBe(404);
      expect(response.body.error).toBeDefined();
    });

    it('should return 405 for unsupported methods', async () => {
      const response = await api.handleRequest('DELETE', '/api/sessions', {});

      expect(response.status).toBe(405);
    });
  });

  describe('POST /api/sessions', () => {
    it('should create a session', async () => {
      const response = await api.handleRequest('POST', '/api/sessions', {
        body: {
          workingDirectory: '/test/path',
          model: 'claude-sonnet-4-20250514',
        },
      });

      expect(response.status).toBe(201);
      expect(response.body.sessionId).toBe('session-123');
      expect(mockContext.createSession).toHaveBeenCalledWith({
        workingDirectory: '/test/path',
        model: 'claude-sonnet-4-20250514',
      });
    });

    it('should return 400 for missing workingDirectory', async () => {
      const response = await api.handleRequest('POST', '/api/sessions', {
        body: {},
      });

      expect(response.status).toBe(400);
      expect(response.body.error.code).toBe('INVALID_PARAMS');
    });
  });

  describe('GET /api/sessions', () => {
    it('should list sessions', async () => {
      const response = await api.handleRequest('GET', '/api/sessions', {});

      expect(response.status).toBe(200);
      expect(response.body.sessions).toHaveLength(2);
      expect(mockContext.listSessions).toHaveBeenCalled();
    });

    it('should pass query parameters', async () => {
      await api.handleRequest('GET', '/api/sessions', {
        query: { limit: '10', workspaceId: 'ws-1' },
      });

      expect(mockContext.listSessions).toHaveBeenCalledWith(
        expect.objectContaining({
          limit: 10,
          workspaceId: 'ws-1',
        })
      );
    });
  });

  describe('GET /api/sessions/:id/status', () => {
    it('should get session status', async () => {
      const response = await api.handleRequest(
        'GET',
        '/api/sessions/session-123/status',
        {}
      );

      expect(response.status).toBe(200);
      expect(response.body.isRunning).toBe(false);
      expect(mockContext.getSessionState).toHaveBeenCalledWith('session-123');
    });

    it('should return 404 for non-existent session', async () => {
      const err = new Error('Session not found');
      (err as any).code = 'SESSION_NOT_FOUND';
      mockContext.getSessionState = vi.fn().mockRejectedValue(err);

      const response = await api.handleRequest(
        'GET',
        '/api/sessions/non-existent/status',
        {}
      );

      expect(response.status).toBe(404);
    });
  });

  describe('POST /api/sessions/:id/prompt', () => {
    it('should send a prompt', async () => {
      const response = await api.handleRequest(
        'POST',
        '/api/sessions/session-123/prompt',
        {
          body: {
            prompt: 'Hello, world!',
          },
        }
      );

      expect(response.status).toBe(202);
      expect(response.body.acknowledged).toBe(true);
      expect(response.body.runId).toBe('run_abc123');
      expect(mockContext.sendPrompt).toHaveBeenCalledWith('session-123', {
        prompt: 'Hello, world!',
      });
    });

    it('should return 400 for missing prompt', async () => {
      const response = await api.handleRequest(
        'POST',
        '/api/sessions/session-123/prompt',
        {
          body: {},
        }
      );

      expect(response.status).toBe(400);
    });

    it('should pass optional parameters', async () => {
      await api.handleRequest('POST', '/api/sessions/session-123/prompt', {
        body: {
          prompt: 'Test',
          reasoningLevel: 'high',
          idempotencyKey: 'key-123',
        },
      });

      expect(mockContext.sendPrompt).toHaveBeenCalledWith('session-123', {
        prompt: 'Test',
        reasoningLevel: 'high',
        idempotencyKey: 'key-123',
      });
    });
  });

  describe('POST /api/sessions/:id/abort', () => {
    it('should abort a session', async () => {
      const response = await api.handleRequest(
        'POST',
        '/api/sessions/session-123/abort',
        {}
      );

      expect(response.status).toBe(200);
      expect(response.body.aborted).toBe(true);
      expect(mockContext.abortSession).toHaveBeenCalledWith('session-123');
    });
  });

  describe('authentication', () => {
    it('should reject requests without auth when required', async () => {
      const authApi = createHttpApi(
        { ...config, requireAuth: true },
        mockContext
      );

      const response = await authApi.handleRequest('GET', '/api/sessions', {});

      expect(response.status).toBe(401);
    });

    it('should accept requests with valid Bearer token', async () => {
      const authApi = createHttpApi(
        { ...config, requireAuth: true, authToken: 'secret-token' },
        mockContext
      );

      const response = await authApi.handleRequest('GET', '/api/sessions', {
        headers: { authorization: 'Bearer secret-token' },
      });

      expect(response.status).toBe(200);
    });

    it('should reject requests with invalid token', async () => {
      const authApi = createHttpApi(
        { ...config, requireAuth: true, authToken: 'secret-token' },
        mockContext
      );

      const response = await authApi.handleRequest('GET', '/api/sessions', {
        headers: { authorization: 'Bearer wrong-token' },
      });

      expect(response.status).toBe(401);
    });
  });

  describe('CORS', () => {
    it('should include CORS headers when enabled', async () => {
      const response = await api.handleRequest('GET', '/api/sessions', {});

      expect(response.headers?.['Access-Control-Allow-Origin']).toBe('*');
    });

    it('should handle OPTIONS preflight', async () => {
      const response = await api.handleRequest('OPTIONS', '/api/sessions', {});

      expect(response.status).toBe(204);
      expect(response.headers?.['Access-Control-Allow-Methods']).toBeDefined();
    });
  });

  describe('error handling', () => {
    it('should return structured error for internal errors', async () => {
      mockContext.listSessions = vi.fn().mockRejectedValue(
        new Error('Database error')
      );

      const response = await api.handleRequest('GET', '/api/sessions', {});

      expect(response.status).toBe(500);
      expect(response.body.error.code).toBe('INTERNAL_ERROR');
      expect(response.body.error.message).toBeDefined();
    });
  });
});

describe('Route matching', () => {
  let api: HttpApi;
  let mockContext: HttpApiContext;

  beforeEach(() => {
    mockContext = createMockContext();
    api = createHttpApi({ basePath: '/api' }, mockContext);
  });

  it('should extract session ID from path', async () => {
    await api.handleRequest('GET', '/api/sessions/my-session-id/status', {});

    expect(mockContext.getSessionState).toHaveBeenCalledWith('my-session-id');
  });

  it('should handle paths with trailing slash', async () => {
    const response1 = await api.handleRequest('GET', '/api/sessions/', {});
    const response2 = await api.handleRequest('GET', '/api/sessions', {});

    expect(response1.status).toBe(response2.status);
  });
});
