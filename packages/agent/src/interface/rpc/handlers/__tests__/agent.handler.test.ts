/**
 * @fileoverview Tests for Agent RPC Handlers
 *
 * Tests agent.prompt, agent.abort, agent.getState handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createAgentHandlers } from '../agent.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Agent Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutAgentManager: RpcContext;
  let mockPrompt: ReturnType<typeof vi.fn>;
  let mockAbort: ReturnType<typeof vi.fn>;
  let mockGetState: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createAgentHandlers());

    mockPrompt = vi.fn().mockResolvedValue({
      response: 'Hello! How can I help you?',
      tokensUsed: { input: 100, output: 50 },
    });

    mockAbort = vi.fn().mockResolvedValue({
      aborted: true,
      reason: 'User requested abort',
    });

    mockGetState = vi.fn().mockResolvedValue({
      isRunning: false,
      currentTool: null,
      pendingToolCalls: [],
      lastActivity: '2024-01-15T10:00:00Z',
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {
        prompt: mockPrompt,
        abort: mockAbort,
        getState: mockGetState,
      } as any,
    };

    mockContextWithoutAgentManager = {
      sessionManager: {} as any,
    };
  });

  describe('agent.prompt', () => {
    it('should send a prompt to the agent', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.prompt',
        params: {
          sessionId: 'sess-123',
          prompt: 'Hello, how are you?',
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockPrompt).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        prompt: 'Hello, how are you?',
      });
      const result = response.result as { response: string };
      expect(result.response).toBe('Hello! How can I help you?');
    });

    it('should pass additional prompt options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.prompt',
        params: {
          sessionId: 'sess-123',
          prompt: 'Write code',
          images: [{ type: 'base64', data: 'abc123' }],
          maxTurns: 5,
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockPrompt).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        prompt: 'Write code',
        images: [{ type: 'base64', data: 'abc123' }],
        maxTurns: 5,
      });
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.prompt',
        params: { prompt: 'Hello' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing prompt', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.prompt',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('prompt');
    });

    it('should return NOT_AVAILABLE without agentManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.prompt',
        params: { sessionId: 'sess-123', prompt: 'Hello' },
      };

      const response = await registry.dispatch(request, mockContextWithoutAgentManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('agent.abort', () => {
    it('should abort the agent operation', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.abort',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockAbort).toHaveBeenCalledWith('sess-123');
      const result = response.result as { aborted: boolean };
      expect(result.aborted).toBe(true);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.abort',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_AVAILABLE without agentManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.abort',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutAgentManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('agent.getState', () => {
    it('should get the agent state', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.getState',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetState).toHaveBeenCalledWith('sess-123');
      const result = response.result as { isRunning: boolean };
      expect(result.isRunning).toBe(false);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.getState',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return NOT_AVAILABLE without agentManager', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'agent.getState',
        params: { sessionId: 'sess-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutAgentManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('createAgentHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createAgentHandlers();

      expect(handlers).toHaveLength(3);
      const methods = handlers.map(h => h.method);
      expect(methods).toContain('agent.prompt');
      expect(methods).toContain('agent.abort');
      expect(methods).toContain('agent.getState');
    });

    it('should have correct options for agent.prompt', () => {
      const handlers = createAgentHandlers();
      const promptHandler = handlers.find(h => h.method === 'agent.prompt');

      expect(promptHandler?.options?.requiredParams).toContain('sessionId');
      expect(promptHandler?.options?.requiredParams).toContain('prompt');
      expect(promptHandler?.options?.requiredManagers).toContain('agentManager');
    });

    it('should have agentManager as required for all handlers', () => {
      const handlers = createAgentHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('agentManager');
      }
    });
  });
});
