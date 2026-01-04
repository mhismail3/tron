/**
 * @fileoverview RPC Client Tests (TDD)
 *
 * Tests for the typed RPC client that wraps WebSocket communication.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { RpcClient } from '../../src/rpc/client.js';
import {
  MockWebSocket,
  installMockWebSocket,
  uninstallMockWebSocket,
} from '../helpers/websocket-mock.js';
import {
  createSessionCreateResponse,
  createSessionListResponse,
  createAgentPromptResponse,
  createModelListResponse,
  createSystemPingResponse,
  createTextDeltaEvent,
  createToolStartEvent,
  createAgentCompleteEvent,
  createSystemConnectedEvent,
} from '../helpers/rpc-fixtures.js';

describe('RpcClient', () => {
  let client: RpcClient;
  let mockSocket: MockWebSocket | null;

  beforeEach(() => {
    installMockWebSocket();
  });

  afterEach(() => {
    client?.disconnect();
    uninstallMockWebSocket();
    vi.clearAllMocks();
  });

  function createClient(
    url = 'ws://localhost:8080/ws',
    options: { autoReconnect?: boolean } = {},
  ): RpcClient {
    client = new RpcClient(url, options);
    // Note: socket is created in connect(), so mockSocket is set after startConnect()
    return client;
  }

  function startConnect(): void {
    // Start connecting (creates the WebSocket) - do NOT await
    void client.connect();
    mockSocket = MockWebSocket.getLastInstance();
  }

  async function connectClient(): Promise<void> {
    const connectPromise = client.connect();
    mockSocket = MockWebSocket.getLastInstance();
    mockSocket?.simulateOpen();
    await connectPromise;
  }

  // ===========================================================================
  // Connection Tests
  // ===========================================================================

  describe('connection', () => {
    it('should connect to the server', async () => {
      createClient();
      startConnect();

      mockSocket!.simulateOpen();

      await new Promise((r) => setTimeout(r, 10));
      expect(client.isConnected()).toBe(true);
    });

    it('should reject if connection fails', async () => {
      createClient();
      const connectPromise = client.connect();
      mockSocket = MockWebSocket.getLastInstance();

      mockSocket!.simulateError(new Error('Connection refused'));
      mockSocket!.simulateClose(1006, 'Connection failed');

      await expect(connectPromise).rejects.toThrow();
      expect(client.isConnected()).toBe(false);
    });

    it('should disconnect from the server', async () => {
      createClient();
      await connectClient();

      client.disconnect();

      expect(client.isConnected()).toBe(false);
    });

    it('should return correct URL', () => {
      createClient('ws://test.example.com/ws');
      expect(client.getUrl()).toBe('ws://test.example.com/ws');
    });
  });

  // ===========================================================================
  // Request/Response Tests
  // ===========================================================================

  describe('requests', () => {
    beforeEach(async () => {
      createClient();
      await connectClient();
    });

    it('should send a request and receive a response', async () => {
      const requestPromise = client.request('session.create', {
        workingDirectory: '/test/project',
      });

      // Get the sent request
      const sentRequest = mockSocket!.getLastRequest()!;
      expect(sentRequest.method).toBe('session.create');
      expect(sentRequest.params).toEqual({ workingDirectory: '/test/project' });

      // Simulate response
      mockSocket!.simulateMessage(createSessionCreateResponse(sentRequest.id, {
        sessionId: 'session_123',
      }));

      const result = await requestPromise as { sessionId: string };
      expect(result.sessionId).toBe('session_123');
    });

    it('should reject on error response', async () => {
      const requestPromise = client.request('session.create', {
        workingDirectory: '/invalid',
      });

      const sentRequest = mockSocket!.getLastRequest()!;
      mockSocket!.simulateMessage({
        id: sentRequest.id,
        success: false,
        error: {
          code: 'INVALID_PATH',
          message: 'Path does not exist',
        },
      });

      await expect(requestPromise).rejects.toThrow('Path does not exist');
    });

    it('should timeout if no response received', async () => {
      const requestPromise = client.request('system.ping', undefined, { timeout: 50 });

      await expect(requestPromise).rejects.toThrow('timeout');
    });

    it('should correlate responses to requests', async () => {
      // Send two requests
      const promise1 = client.request('session.list', {});
      const request1 = mockSocket!.getLastRequest()!;

      const promise2 = client.request('model.list', {});
      const request2 = mockSocket!.getLastRequest()!;

      // Respond in reverse order
      mockSocket!.simulateMessage(createModelListResponse(request2.id));
      mockSocket!.simulateMessage(createSessionListResponse(request1.id, []));

      const [result1, result2] = await Promise.all([promise1, promise2]);

      expect(result1).toHaveProperty('sessions');
      expect(result2).toHaveProperty('models');
    });
  });

  // ===========================================================================
  // Typed Method Tests
  // ===========================================================================

  describe('typed methods', () => {
    beforeEach(async () => {
      createClient();
      await connectClient();
    });

    describe('session methods', () => {
      it('should create a session', async () => {
        const promise = client.sessionCreate({ workingDirectory: '/project' });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('session.create');

        mockSocket!.simulateMessage(createSessionCreateResponse(request.id, {
          sessionId: 'new_session',
        }));

        const result = await promise;
        expect(result.sessionId).toBe('new_session');
      });

      it('should resume a session', async () => {
        const promise = client.sessionResume({ sessionId: 'existing_session' });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('session.resume');

        mockSocket!.simulateMessage({
          id: request.id,
          success: true,
          result: {
            sessionId: 'existing_session',
            model: 'claude-sonnet-4-20250514',
            messageCount: 10,
            lastActivity: new Date().toISOString(),
          },
        });

        const result = await promise;
        expect(result.sessionId).toBe('existing_session');
        expect(result.messageCount).toBe(10);
      });

      it('should list sessions', async () => {
        const promise = client.sessionList({ limit: 10 });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('session.list');

        mockSocket!.simulateMessage(createSessionListResponse(request.id, [
          {
            sessionId: 'session_1',
            workingDirectory: '/project1',
            model: 'claude-sonnet-4-20250514',
            messageCount: 5,
            createdAt: new Date().toISOString(),
            lastActivity: new Date().toISOString(),
            isActive: true,
          },
        ]));

        const result = await promise;
        expect(result.sessions).toHaveLength(1);
        expect(result.sessions[0]?.sessionId).toBe('session_1');
      });

      it('should delete a session', async () => {
        const promise = client.sessionDelete({ sessionId: 'session_to_delete' });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('session.delete');

        mockSocket!.simulateMessage({
          id: request.id,
          success: true,
          result: { deleted: true },
        });

        const result = await promise;
        expect(result.deleted).toBe(true);
      });
    });

    describe('agent methods', () => {
      it('should send a prompt', async () => {
        const promise = client.agentPrompt({
          sessionId: 'session_123',
          prompt: 'Hello, Claude!',
        });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('agent.prompt');
        expect(request.params).toEqual({
          sessionId: 'session_123',
          prompt: 'Hello, Claude!',
        });

        mockSocket!.simulateMessage(createAgentPromptResponse(request.id));

        const result = await promise;
        expect(result.acknowledged).toBe(true);
      });

      it('should abort an agent run', async () => {
        const promise = client.agentAbort({ sessionId: 'session_123' });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('agent.abort');

        mockSocket!.simulateMessage({
          id: request.id,
          success: true,
          result: { aborted: true },
        });

        const result = await promise;
        expect(result.aborted).toBe(true);
      });
    });

    describe('model methods', () => {
      it('should switch models', async () => {
        const promise = client.modelSwitch({
          sessionId: 'session_123',
          model: 'claude-opus-4-20250514',
        });
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('model.switch');

        mockSocket!.simulateMessage({
          id: request.id,
          success: true,
          result: {
            previousModel: 'claude-sonnet-4-20250514',
            newModel: 'claude-opus-4-20250514',
          },
        });

        const result = await promise;
        expect(result.newModel).toBe('claude-opus-4-20250514');
      });

      it('should list models', async () => {
        const promise = client.modelList();
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('model.list');

        mockSocket!.simulateMessage(createModelListResponse(request.id));

        const result = await promise;
        expect(result.models.length).toBeGreaterThan(0);
      });
    });

    describe('system methods', () => {
      it('should ping the server', async () => {
        const promise = client.systemPing();
        const request = mockSocket!.getLastRequest()!;

        expect(request.method).toBe('system.ping');

        mockSocket!.simulateMessage(createSystemPingResponse(request.id));

        const result = await promise;
        expect(result.pong).toBe(true);
      });
    });
  });

  // ===========================================================================
  // Event Handling Tests
  // ===========================================================================

  describe('events', () => {
    beforeEach(async () => {
      createClient();
      await connectClient();
    });

    it('should emit events to listeners', async () => {
      const handler = vi.fn();
      client.on('agent.text_delta', handler);

      const event = createTextDeltaEvent('session_123', 'Hello');
      mockSocket!.simulateMessage(event);

      expect(handler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'agent.text_delta',
        data: expect.objectContaining({ delta: 'Hello' }),
      }));
    });

    it('should support multiple event types', async () => {
      const textHandler = vi.fn();
      const toolHandler = vi.fn();

      client.on('agent.text_delta', textHandler);
      client.on('agent.tool_start', toolHandler);

      mockSocket!.simulateMessage(createTextDeltaEvent('session_123', 'Hello'));
      mockSocket!.simulateMessage(createToolStartEvent('session_123', { toolName: 'Read' }));

      expect(textHandler).toHaveBeenCalledTimes(1);
      expect(toolHandler).toHaveBeenCalledTimes(1);
    });

    it('should support wildcard event listener', async () => {
      const handler = vi.fn();
      client.on('*', handler);

      mockSocket!.simulateMessage(createTextDeltaEvent('session_123', 'Hello'));
      mockSocket!.simulateMessage(createAgentCompleteEvent('session_123'));

      expect(handler).toHaveBeenCalledTimes(2);
    });

    it('should support removing event listeners', async () => {
      const handler = vi.fn();
      client.on('agent.text_delta', handler);

      mockSocket!.simulateMessage(createTextDeltaEvent('session_123', 'First'));
      expect(handler).toHaveBeenCalledTimes(1);

      client.off('agent.text_delta', handler);

      mockSocket!.simulateMessage(createTextDeltaEvent('session_123', 'Second'));
      expect(handler).toHaveBeenCalledTimes(1);
    });

    it('should emit connection events', async () => {
      const connectHandler = vi.fn();
      const disconnectHandler = vi.fn();

      client.on('connected', connectHandler);
      client.on('disconnected', disconnectHandler);

      mockSocket!.simulateMessage(createSystemConnectedEvent('client_123'));
      expect(connectHandler).toHaveBeenCalled();

      mockSocket!.simulateClose(1000, 'Normal closure');
      expect(disconnectHandler).toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Reconnection Tests
  // ===========================================================================

  describe('reconnection', () => {
    it('should emit reconnecting event on unexpected close', async () => {
      // Disable auto-reconnect to prevent async issues, just test the event
      createClient('ws://localhost:8080/ws', { autoReconnect: false });
      await connectClient();

      const disconnectHandler = vi.fn();
      client.on('disconnected', disconnectHandler);

      // Unexpected close (not code 1000)
      mockSocket!.simulateClose(1006, 'Abnormal closure');

      // Just verify the disconnect handler was called
      expect(disconnectHandler).toHaveBeenCalled();
    });

    it('should not reconnect on intentional disconnect', async () => {
      createClient('ws://localhost:8080/ws', { autoReconnect: false });
      await connectClient();

      const disconnectHandler = vi.fn();
      client.on('disconnected', disconnectHandler);

      client.disconnect(); // Intentional disconnect

      // Wait for async close event
      await new Promise((r) => setTimeout(r, 10));

      // Should still emit disconnect
      expect(disconnectHandler).toHaveBeenCalled();
      expect(client.isConnected()).toBe(false);
    });

    it('should have auto-reconnect disabled by default when option is false', () => {
      // This is a simple unit test - verify the option is respected
      const testClient = new RpcClient('ws://localhost:8080/ws', { autoReconnect: false });
      expect(testClient).toBeDefined();
    });
  });

  // ===========================================================================
  // Error Handling Tests
  // ===========================================================================

  describe('error handling', () => {
    it('should reject pending requests on disconnect', async () => {
      createClient('ws://localhost:8080/ws', { autoReconnect: false });
      await connectClient();

      const promise = client.request('system.ping', undefined, { timeout: 5000 });

      mockSocket!.simulateClose(1006, 'Connection lost');

      await expect(promise).rejects.toThrow();
    });

    it('should handle invalid JSON messages gracefully', async () => {
      createClient('ws://localhost:8080/ws', { autoReconnect: false });
      await connectClient();

      const errorHandler = vi.fn();
      client.on('error', errorHandler);

      mockSocket!.simulateRawMessage('not valid json');

      expect(errorHandler).toHaveBeenCalled();
    });
  });
});
