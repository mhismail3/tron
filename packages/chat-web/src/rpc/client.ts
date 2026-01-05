/**
 * @fileoverview Typed RPC Client
 *
 * Provides a typed wrapper around WebSocket for communicating with
 * the Tron server using the RPC protocol.
 */

import type {
  RpcRequest,
  RpcResponse,
  RpcEvent,
  RpcMethod,
  RpcEventType,
  SessionCreateParams,
  SessionCreateResult,
  SessionResumeParams,
  SessionResumeResult,
  SessionListParams,
  SessionListResult,
  SessionDeleteParams,
  SessionDeleteResult,
  SessionForkParams,
  SessionForkResult,
  SessionRewindParams,
  SessionRewindResult,
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  AgentGetStateResult,
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListParams,
  ModelListResult,
  SystemPingParams,
  SystemPingResult,
  SystemGetInfoParams,
  SystemGetInfoResult,
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeParams,
  FilesystemGetHomeResult,
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListParams,
  WorktreeListResult,
} from '@tron/core/browser';

// =============================================================================
// Types
// =============================================================================

export interface RpcClientOptions {
  /** Default request timeout in ms */
  timeout?: number;
  /** Enable auto-reconnect */
  autoReconnect?: boolean;
  /** Reconnect delay base (ms), doubles each attempt */
  reconnectDelay?: number;
  /** Maximum reconnect attempts */
  maxReconnectAttempts?: number;
}

export interface RequestOptions {
  /** Request timeout in ms */
  timeout?: number;
}

type EventHandler<T = RpcEvent> = (event: T) => void;
type ConnectionHandler = () => void;
type ErrorHandler = (error: Error) => void;
type ReconnectHandler = (attempt: number) => void;

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

// =============================================================================
// RpcClient
// =============================================================================

export class RpcClient {
  private url: string;
  private options: Required<RpcClientOptions>;
  private socket: WebSocket | null = null;
  private pendingRequests: Map<string, PendingRequest> = new Map();
  private eventHandlers: Map<string, Set<EventHandler>> = new Map();
  private connectionHandlers: {
    connected: Set<ConnectionHandler>;
    disconnected: Set<ConnectionHandler>;
    reconnecting: Set<ReconnectHandler>;
    error: Set<ErrorHandler>;
  } = {
    connected: new Set(),
    disconnected: new Set(),
    reconnecting: new Set(),
    error: new Set(),
  };
  private requestIdCounter = 0;
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private intentionalClose = false;

  constructor(url: string, options: RpcClientOptions = {}) {
    this.url = url;
    this.options = {
      timeout: options.timeout ?? 30000,
      autoReconnect: options.autoReconnect ?? true,
      reconnectDelay: options.reconnectDelay ?? 1000,
      maxReconnectAttempts: options.maxReconnectAttempts ?? 5,
    };
  }

  // ===========================================================================
  // Connection Management
  // ===========================================================================

  /**
   * Connect to the WebSocket server
   */
  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      console.log('[RpcClient] connect() called, current readyState=%s', this.socket?.readyState);

      // Already connected
      if (this.socket?.readyState === WebSocket.OPEN) {
        console.log('[RpcClient] Already connected');
        resolve();
        return;
      }

      // Already connecting - wait for that connection
      if (this.socket?.readyState === WebSocket.CONNECTING) {
        console.log('[RpcClient] Already connecting, waiting...');
        const checkInterval = setInterval(() => {
          if (this.socket?.readyState === WebSocket.OPEN) {
            clearInterval(checkInterval);
            resolve();
          } else if (!this.socket || this.socket.readyState > WebSocket.OPEN) {
            clearInterval(checkInterval);
            reject(new Error('Connection failed while waiting'));
          }
        }, 50);
        return;
      }

      this.intentionalClose = false;
      console.log('[RpcClient] Creating WebSocket to', this.url);
      const socket = new WebSocket(this.url);
      this.socket = socket;

      socket.onopen = () => {
        // Verify this is still our current socket (not a stale reference)
        if (this.socket !== socket) {
          console.log('[RpcClient] Ignoring OPEN from stale socket');
          return;
        }
        console.log('[RpcClient] WebSocket OPEN, readyState=%s', socket.readyState);
        this.reconnectAttempts = 0;
        // Emit connected event immediately when socket opens
        for (const handler of this.connectionHandlers.connected) {
          handler();
        }
        resolve();
      };

      socket.onclose = (event) => {
        // Verify this is still our current socket
        if (this.socket !== socket) {
          console.log('[RpcClient] Ignoring CLOSE from stale socket');
          return;
        }
        console.log('[RpcClient] WebSocket CLOSE, code=%d, reason=%s', event.code, event.reason);
        this.handleClose(event.code, event.reason);
      };

      socket.onerror = (event) => {
        // Verify this is still our current socket
        if (this.socket !== socket) {
          console.log('[RpcClient] Ignoring ERROR from stale socket');
          return;
        }
        console.error('[RpcClient] WebSocket ERROR', event);
        const error = new Error('WebSocket connection failed');
        reject(error);
        this.emitConnectionError(error);
      };

      socket.onmessage = (event) => {
        // Verify this is still our current socket
        if (this.socket !== socket) {
          return;
        }
        this.handleMessage(event.data);
      };
    });
  }

  /**
   * Disconnect from the server
   */
  disconnect(): void {
    console.log('[RpcClient] disconnect() called, readyState=%s', this.socket?.readyState);
    this.intentionalClose = true;
    this.cancelReconnect();
    this.rejectAllPending('Connection closed');

    if (this.socket) {
      // Clear handlers before closing to prevent stale callbacks
      const socket = this.socket;
      this.socket = null;
      socket.onopen = null;
      socket.onclose = null;
      socket.onerror = null;
      socket.onmessage = null;
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close(1000, 'Client disconnect');
      }
    }
  }

  /**
   * Check if connected
   */
  isConnected(): boolean {
    return this.socket?.readyState === WebSocket.OPEN;
  }

  /**
   * Get the WebSocket URL
   */
  getUrl(): string {
    return this.url;
  }

  // ===========================================================================
  // Request/Response
  // ===========================================================================

  /**
   * Send an RPC request and wait for response
   */
  request<TResult>(
    method: RpcMethod,
    params?: unknown,
    options: RequestOptions = {},
  ): Promise<TResult> {
    return new Promise((resolve, reject) => {
      if (!this.isConnected()) {
        reject(new Error('Not connected'));
        return;
      }

      const id = this.generateRequestId();
      const timeout = options.timeout ?? this.options.timeout;

      const request: RpcRequest = {
        id,
        method,
        params,
      };

      const timer = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, timeout);

      this.pendingRequests.set(id, {
        resolve: resolve as (result: unknown) => void,
        reject,
        timer,
      });

      // Double-check socket is still open before sending
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
        clearTimeout(timer);
        this.pendingRequests.delete(id);
        reject(new Error('Not connected'));
        return;
      }

      this.socket.send(JSON.stringify(request));
    });
  }

  // ===========================================================================
  // Typed Methods
  // ===========================================================================

  // Session methods
  sessionCreate(params: SessionCreateParams): Promise<SessionCreateResult> {
    return this.request('session.create', params);
  }

  sessionResume(params: SessionResumeParams): Promise<SessionResumeResult> {
    return this.request('session.resume', params);
  }

  sessionList(params?: SessionListParams): Promise<SessionListResult> {
    return this.request('session.list', params);
  }

  sessionDelete(params: SessionDeleteParams): Promise<SessionDeleteResult> {
    return this.request('session.delete', params);
  }

  sessionFork(params: SessionForkParams): Promise<SessionForkResult> {
    return this.request('session.fork', params);
  }

  sessionRewind(params: SessionRewindParams): Promise<SessionRewindResult> {
    return this.request('session.rewind', params);
  }

  // Agent methods
  agentPrompt(params: AgentPromptParams): Promise<AgentPromptResult> {
    return this.request('agent.prompt', params);
  }

  agentAbort(params: AgentAbortParams): Promise<AgentAbortResult> {
    return this.request('agent.abort', params);
  }

  agentGetState(params: AgentGetStateParams): Promise<AgentGetStateResult> {
    return this.request('agent.getState', params);
  }

  // Model methods
  modelSwitch(params: ModelSwitchParams): Promise<ModelSwitchResult> {
    return this.request('model.switch', params);
  }

  modelList(params?: ModelListParams): Promise<ModelListResult> {
    return this.request('model.list', params);
  }

  // System methods
  systemPing(params?: SystemPingParams): Promise<SystemPingResult> {
    return this.request('system.ping', params);
  }

  systemGetInfo(params?: SystemGetInfoParams): Promise<SystemGetInfoResult> {
    return this.request('system.getInfo', params);
  }

  // Filesystem methods
  filesystemListDir(params?: FilesystemListDirParams): Promise<FilesystemListDirResult> {
    return this.request('filesystem.listDir', params);
  }

  filesystemGetHome(params?: FilesystemGetHomeParams): Promise<FilesystemGetHomeResult> {
    return this.request('filesystem.getHome', params);
  }

  // Worktree methods
  worktreeGetStatus(params: WorktreeGetStatusParams): Promise<WorktreeGetStatusResult> {
    return this.request('worktree.getStatus', params);
  }

  worktreeCommit(params: WorktreeCommitParams): Promise<WorktreeCommitResult> {
    return this.request('worktree.commit', params);
  }

  worktreeMerge(params: WorktreeMergeParams): Promise<WorktreeMergeResult> {
    return this.request('worktree.merge', params);
  }

  worktreeList(params?: WorktreeListParams): Promise<WorktreeListResult> {
    return this.request('worktree.list', params);
  }

  // ===========================================================================
  // Event Handling
  // ===========================================================================

  /**
   * Subscribe to RPC events
   */
  on(event: RpcEventType | '*', handler: EventHandler): void;
  on(event: 'connected', handler: ConnectionHandler): void;
  on(event: 'disconnected', handler: ConnectionHandler): void;
  on(event: 'reconnecting', handler: ReconnectHandler): void;
  on(event: 'error', handler: ErrorHandler): void;
  on(
    event: RpcEventType | '*' | 'connected' | 'disconnected' | 'reconnecting' | 'error',
    handler: EventHandler | ConnectionHandler | ReconnectHandler | ErrorHandler,
  ): void {
    if (event === 'connected') {
      this.connectionHandlers.connected.add(handler as ConnectionHandler);
    } else if (event === 'disconnected') {
      this.connectionHandlers.disconnected.add(handler as ConnectionHandler);
    } else if (event === 'reconnecting') {
      this.connectionHandlers.reconnecting.add(handler as ReconnectHandler);
    } else if (event === 'error') {
      this.connectionHandlers.error.add(handler as ErrorHandler);
    } else {
      let handlers = this.eventHandlers.get(event);
      if (!handlers) {
        handlers = new Set();
        this.eventHandlers.set(event, handlers);
      }
      handlers.add(handler as EventHandler);
    }
  }

  /**
   * Unsubscribe from RPC events
   */
  off(event: RpcEventType | '*', handler: EventHandler): void;
  off(event: 'connected', handler: ConnectionHandler): void;
  off(event: 'disconnected', handler: ConnectionHandler): void;
  off(event: 'reconnecting', handler: ReconnectHandler): void;
  off(event: 'error', handler: ErrorHandler): void;
  off(
    event: RpcEventType | '*' | 'connected' | 'disconnected' | 'reconnecting' | 'error',
    handler: EventHandler | ConnectionHandler | ReconnectHandler | ErrorHandler,
  ): void {
    if (event === 'connected') {
      this.connectionHandlers.connected.delete(handler as ConnectionHandler);
    } else if (event === 'disconnected') {
      this.connectionHandlers.disconnected.delete(handler as ConnectionHandler);
    } else if (event === 'reconnecting') {
      this.connectionHandlers.reconnecting.delete(handler as ReconnectHandler);
    } else if (event === 'error') {
      this.connectionHandlers.error.delete(handler as ErrorHandler);
    } else {
      this.eventHandlers.get(event)?.delete(handler as EventHandler);
    }
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private handleMessage(data: string): void {
    try {
      const message = JSON.parse(data);

      // Check if it's a response
      if (this.isResponse(message)) {
        this.handleResponse(message);
        return;
      }

      // Check if it's an event
      if (this.isEvent(message)) {
        this.handleEvent(message);
        return;
      }
    } catch {
      this.emitConnectionError(new Error('Failed to parse message'));
    }
  }

  private handleResponse(response: RpcResponse): void {
    const pending = this.pendingRequests.get(response.id);
    if (!pending) return;

    clearTimeout(pending.timer);
    this.pendingRequests.delete(response.id);

    if (response.success) {
      pending.resolve(response.result);
    } else {
      pending.reject(new Error(response.error?.message ?? 'Request failed'));
    }
  }

  private handleEvent(event: RpcEvent): void {
    // Handle system.connected event
    if (event.type === 'system.connected') {
      for (const handler of this.connectionHandlers.connected) {
        handler();
      }
    }

    // Emit to specific handlers
    const handlers = this.eventHandlers.get(event.type);
    if (handlers) {
      for (const handler of handlers) {
        handler(event);
      }
    }

    // Emit to wildcard handlers
    const wildcardHandlers = this.eventHandlers.get('*');
    if (wildcardHandlers) {
      for (const handler of wildcardHandlers) {
        handler(event);
      }
    }
  }

  private handleClose(code: number, _reason: string): void {
    // Reject all pending requests
    this.rejectAllPending('Connection closed');

    // Emit disconnected
    for (const handler of this.connectionHandlers.disconnected) {
      handler();
    }

    // Attempt reconnection if not intentional
    if (!this.intentionalClose && this.options.autoReconnect && code !== 1000) {
      this.attemptReconnect();
    }
  }

  private attemptReconnect(): void {
    if (this.reconnectAttempts >= this.options.maxReconnectAttempts) {
      return;
    }

    this.reconnectAttempts++;

    // Emit reconnecting
    for (const handler of this.connectionHandlers.reconnecting) {
      handler(this.reconnectAttempts);
    }

    const delay = this.options.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1);

    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.connect();
      } catch {
        // Will trigger another reconnect attempt via handleClose
      }
    }, delay);
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private rejectAllPending(message: string): void {
    for (const [id, pending] of this.pendingRequests) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
      this.pendingRequests.delete(id);
    }
  }

  private emitConnectionError(error: Error): void {
    for (const handler of this.connectionHandlers.error) {
      handler(error);
    }
  }

  private generateRequestId(): string {
    return `req_${++this.requestIdCounter}_${Date.now()}`;
  }

  private isResponse(msg: unknown): msg is RpcResponse {
    return (
      typeof msg === 'object' &&
      msg !== null &&
      'id' in msg &&
      'success' in msg
    );
  }

  private isEvent(msg: unknown): msg is RpcEvent {
    return (
      typeof msg === 'object' &&
      msg !== null &&
      'type' in msg &&
      'timestamp' in msg &&
      'data' in msg
    );
  }
}
