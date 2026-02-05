/**
 * @fileoverview TDD tests for websocket send-pipeline hardening
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'events';
import { WebSocket } from 'ws';
import { TronWebSocketServer } from '../websocket.js';
import type { RpcEvent, RpcResponse } from '../../rpc/index.js';

class FakeSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  autoAcknowledge = true;
  sentMessages: string[] = [];
  pendingCallbacks: Array<((err?: Error | null) => void) | undefined> = [];

  send = vi.fn((message: string, callback?: (err?: Error | null) => void) => {
    this.sentMessages.push(message);
    if (this.autoAcknowledge) {
      setImmediate(() => callback?.());
      return;
    }
    this.pendingCallbacks.push(callback);
  });

  close = vi.fn();
  terminate = vi.fn();
  ping = vi.fn();

  ackNext(error?: Error): void {
    const callback = this.pendingCallbacks.shift();
    callback?.(error);
  }
}

interface TestClient {
  id: string;
  socket: FakeSocket;
  isAlive: boolean;
  connectedAt: Date;
  pendingMessages: number;
  maxPendingMessages: number;
  sendQueue: Array<{ kind: string; payload: string; meta: Record<string, unknown> }>;
  isSending: boolean;
  droppedMessages: number;
  sendFailures: number;
}

function createServer(): TronWebSocketServer {
  return new TronWebSocketServer({ port: 0 }, {} as never);
}

function registerClient(
  server: TronWebSocketServer,
  clientId: string,
  socket: FakeSocket,
  maxPendingMessages = 2
): TestClient {
  const client: TestClient = {
    id: clientId,
    socket,
    isAlive: true,
    connectedAt: new Date(),
    pendingMessages: 0,
    maxPendingMessages,
    sendQueue: [],
    isSending: false,
    droppedMessages: 0,
    sendFailures: 0,
  };

  ((server as unknown as { clients: Map<string, TestClient> }).clients).set(clientId, client);
  return client;
}

describe('TronWebSocketServer send pipeline', () => {
  let server: TronWebSocketServer;

  beforeEach(() => {
    server = createServer();
  });

  it('applies backpressure to sendToClient using the same pending-message accounting as broadcast', () => {
    const socket = new FakeSocket();
    socket.autoAcknowledge = false;
    const client = registerClient(server, 'client_1', socket, 1);

    const firstEvent: RpcEvent = {
      type: 'agent.text_delta',
      timestamp: new Date().toISOString(),
      data: { delta: 'hello' },
    };

    const secondEvent: RpcEvent = {
      type: 'agent.text_delta',
      timestamp: new Date().toISOString(),
      data: { delta: 'world' },
    };

    server.broadcastEvent(firstEvent);
    const accepted = server.sendToClient('client_1', secondEvent);

    expect(client.pendingMessages).toBe(1);
    expect(accepted).toBe(false);
  });

  it('routes sendResponse through the same queue accounting as other send paths', () => {
    const socket = new FakeSocket();
    socket.autoAcknowledge = false;
    const client = registerClient(server, 'client_2', socket, 4);

    server.sendToClient('client_2', {
      type: 'agent.text_delta',
      timestamp: new Date().toISOString(),
      data: { delta: 'A' },
    });

    const response: RpcResponse = { id: 'rpc_1', success: true, result: { ok: true } };
    (server as unknown as { sendResponse: (c: TestClient, r: RpcResponse) => void }).sendResponse(client, response);

    expect(client.pendingMessages).toBe(2);
  });

  it('emits send-error accounting when websocket callback reports a failure', () => {
    const socket = new FakeSocket();
    socket.autoAcknowledge = false;
    registerClient(server, 'client_3', socket, 4);

    const sendErrorSpy = vi.fn();
    server.on('client_send_error', sendErrorSpy);

    const accepted = server.sendToClient('client_3', {
      type: 'agent.text_delta',
      timestamp: new Date().toISOString(),
      data: { delta: 'boom' },
    });

    expect(accepted).toBe(true);

    socket.ackNext(new Error('socket write failed'));

    expect(sendErrorSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        clientId: 'client_3',
      })
    );
  });
});
