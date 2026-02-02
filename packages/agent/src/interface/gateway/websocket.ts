/**
 * @fileoverview WebSocket Server
 *
 * Handles WebSocket connections and routes RPC messages.
 */
import { WebSocketServer, WebSocket } from 'ws';
import { EventEmitter } from 'events';
import { randomUUID } from 'crypto';
import type { IncomingMessage } from 'http';
import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import { RpcHandler, isRpcRequest, type RpcRequest, type RpcResponse, type RpcEvent } from '../rpc/index.js';
import type { RpcContext } from '../rpc/context-types.js';

const logger = createLogger('websocket');

// =============================================================================
// Types
// =============================================================================

export interface WebSocketServerConfig {
  /** Port to listen on */
  port: number;
  /** Host to bind to */
  host?: string;
  /** Path for WebSocket connections */
  path?: string;
  /** Heartbeat interval in ms */
  heartbeatInterval?: number;
}

export interface ClientConnection {
  id: string;
  socket: WebSocket;
  isAlive: boolean;
  sessionId?: string;
  connectedAt: Date;
  /** P1 FIX: Track pending messages for backpressure handling */
  pendingMessages: number;
  /** Maximum pending messages before dropping events */
  maxPendingMessages: number;
}

// =============================================================================
// WebSocket Server
// =============================================================================

export class TronWebSocketServer extends EventEmitter {
  private config: WebSocketServerConfig;
  private wss: WebSocketServer | null = null;
  private clients: Map<string, ClientConnection> = new Map();
  private rpcHandler: RpcHandler;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: WebSocketServerConfig, context: RpcContext) {
    super();
    this.config = config;
    this.rpcHandler = new RpcHandler(context);

    // Forward RPC events to connected clients
    this.rpcHandler.on('event', (event: RpcEvent) => {
      this.broadcastEvent(event);
    });
  }

  /**
   * Start the WebSocket server
   */
  async start(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        this.wss = new WebSocketServer({
          port: this.config.port,
          host: this.config.host ?? '0.0.0.0',
          path: this.config.path ?? '/ws',
        });

        this.wss.on('listening', () => {
          logger.info('WebSocket server started', {
            port: this.config.port,
            host: this.config.host ?? '0.0.0.0',
          });
          this.startHeartbeat();
          resolve();
        });

        this.wss.on('connection', (socket, request) => {
          this.handleConnection(socket, request);
        });

        this.wss.on('error', (error) => {
          const structured = categorizeError(error, { operation: 'websocket_server' });
          logger.error('WebSocket server error', {
            code: structured.code,
            category: LogErrorCategory.NETWORK,
            error: structured.message,
            retryable: structured.retryable,
          });
          this.emit('error', error);
        });

        this.wss.on('close', () => {
          logger.info('WebSocket server closed');
          this.stopHeartbeat();
          this.emit('close');
        });
      } catch (error) {
        reject(error);
      }
    });
  }

  /**
   * Stop the WebSocket server
   */
  async stop(): Promise<void> {
    this.stopHeartbeat();

    // Close all client connections
    for (const client of this.clients.values()) {
      client.socket.close(1000, 'Server shutting down');
    }
    this.clients.clear();

    return new Promise((resolve) => {
      if (this.wss) {
        this.wss.close(() => {
          this.wss = null;
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  /**
   * Get number of connected clients
   */
  getClientCount(): number {
    return this.clients.size;
  }

  /**
   * Get all connected client IDs
   */
  getClientIds(): string[] {
    return Array.from(this.clients.keys());
  }

  /**
   * Broadcast an event to all connected clients
   */
  broadcastEvent(event: RpcEvent): void {
    const message = JSON.stringify(event);

    for (const client of this.clients.values()) {
      if (client.socket.readyState !== WebSocket.OPEN) {
        continue;
      }

      // Filter by sessionId if present
      if (event.sessionId && client.sessionId && event.sessionId !== client.sessionId) {
        continue;
      }

      // P1 FIX: Backpressure check - drop events for slow clients
      if (client.pendingMessages >= client.maxPendingMessages) {
        logger.warn('Client message queue full, dropping event', {
          clientId: client.id,
          pending: client.pendingMessages,
          eventType: event.type,
        });
        continue;
      }

      client.pendingMessages++;
      client.socket.send(message, (err) => {
        client.pendingMessages--;
        if (err) {
          const structured = categorizeError(err, { clientId: client.id, operation: 'send_message' });
          logger.error('Failed to send to client', {
            clientId: client.id,
            code: structured.code,
            category: LogErrorCategory.NETWORK,
            error: structured.message,
            retryable: structured.retryable,
          });
        }
      });
    }
  }

  /**
   * Send an event to a specific client
   */
  sendToClient(clientId: string, event: RpcEvent): boolean {
    const client = this.clients.get(clientId);
    if (client && client.socket.readyState === WebSocket.OPEN) {
      client.socket.send(JSON.stringify(event));
      return true;
    }
    return false;
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private handleConnection(socket: WebSocket, request: IncomingMessage): void {
    const clientId = `client_${randomUUID().replace(/-/g, '').slice(0, 12)}`;

    const client: ClientConnection = {
      id: clientId,
      socket,
      isAlive: true,
      connectedAt: new Date(),
      pendingMessages: 0,
      maxPendingMessages: 100, // P1 FIX: Limit to prevent memory exhaustion
    };

    this.clients.set(clientId, client);

    logger.info('Client connected', {
      clientId,
      remoteAddress: request.socket?.remoteAddress,
    });

    // Send connected event
    this.sendToClient(clientId, {
      type: 'system.connected',
      timestamp: new Date().toISOString(),
      data: { clientId },
    });

    // Handle messages
    socket.on('message', async (data) => {
      await this.handleMessage(client, data.toString());
    });

    // Handle pong for heartbeat
    socket.on('pong', () => {
      client.isAlive = true;
    });

    // Handle close
    socket.on('close', (code, reason) => {
      this.clients.delete(clientId);
      logger.info('Client disconnected', { clientId, code, reason: reason.toString() });
      this.emit('client_disconnected', { clientId, code, reason: reason.toString() });
    });

    // Handle errors
    socket.on('error', (error) => {
      const structured = categorizeError(error, { clientId, operation: 'client_socket' });
      logger.error('Client socket error', {
        clientId,
        code: structured.code,
        category: LogErrorCategory.NETWORK,
        error: structured.message,
        retryable: structured.retryable,
      });
      this.emit('client_error', { clientId, error });
    });

    this.emit('client_connected', { clientId });
  }

  private async handleMessage(client: ClientConnection, rawMessage: string): Promise<void> {
    try {
      const message = JSON.parse(rawMessage);

      if (isRpcRequest(message)) {
        await this.handleRpcRequest(client, message);
      } else {
        logger.warn('Invalid message format', { clientId: client.id });
        this.sendError(client, 'INVALID_FORMAT', 'Message must be a valid RPC request');
      }
    } catch (error) {
      const structured = categorizeError(error, { clientId: client.id, operation: 'parse_message' });
      logger.error('Failed to parse message', {
        clientId: client.id,
        code: structured.code,
        category: LogErrorCategory.NETWORK,
        error: structured.message,
        retryable: structured.retryable,
      });
      this.sendError(client, 'PARSE_ERROR', 'Failed to parse message as JSON');
    }
  }

  private async handleRpcRequest(client: ClientConnection, request: RpcRequest): Promise<void> {
    logger.debug('RPC request', { clientId: client.id, method: request.method });

    try {
      // Handle special session binding
      if (request.method === 'session.create' || request.method === 'session.resume') {
        const response = await this.rpcHandler.handle(request);

        if (response.success && response.result) {
          // Bind client to session
          const sessionId = (response.result as { sessionId?: string }).sessionId;
          if (sessionId) {
            client.sessionId = sessionId;
          }
        }

        this.sendResponse(client, response);
        return;
      }

      const response = await this.rpcHandler.handle(request);
      this.sendResponse(client, response);
    } catch (error) {
      const structured = categorizeError(error, { clientId: client.id, method: request.method, operation: 'rpc_handler' });
      logger.error('RPC handler error', {
        clientId: client.id,
        method: request.method,
        code: structured.code,
        category: LogErrorCategory.NETWORK,
        error: structured.message,
        retryable: structured.retryable,
      });
      this.sendResponse(client, {
        id: request.id,
        success: false,
        error: {
          code: 'INTERNAL_ERROR',
          message: structured.message,
        },
      });
    }
  }

  private sendResponse(client: ClientConnection, response: RpcResponse): void {
    if (client.socket.readyState === WebSocket.OPEN) {
      client.socket.send(JSON.stringify(response));
    }
  }

  private sendError(client: ClientConnection, code: string, message: string): void {
    if (client.socket.readyState === WebSocket.OPEN) {
      client.socket.send(JSON.stringify({
        type: 'system.error',
        timestamp: new Date().toISOString(),
        data: { code, message },
      }));
    }
  }

  private startHeartbeat(): void {
    const interval = this.config.heartbeatInterval ?? 30000;

    this.heartbeatTimer = setInterval(() => {
      for (const [clientId, client] of this.clients.entries()) {
        if (!client.isAlive) {
          // Client didn't respond to last ping
          logger.info('Client heartbeat timeout', { clientId });
          client.socket.terminate();
          this.clients.delete(clientId);
          continue;
        }

        client.isAlive = false;
        client.socket.ping();
      }
    }, interval);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }
}
