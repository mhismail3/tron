/**
 * @fileoverview Mock WebSocket for Testing
 *
 * Provides a controllable mock WebSocket for testing RPC client behavior.
 */

import type {
  RpcRequest,
  RpcResponse,
  RpcEvent,
} from '@tron/agent';

// =============================================================================
// Types
// =============================================================================

export type WebSocketReadyState = 0 | 1 | 2 | 3;

export const READY_STATE = {
  CONNECTING: 0 as const,
  OPEN: 1 as const,
  CLOSING: 2 as const,
  CLOSED: 3 as const,
};

export interface MockWebSocketOptions {
  /** Delay before connection opens (ms). Use -1 to disable auto-open (default). */
  connectionDelay?: number;
  /** Auto-respond to requests with success */
  autoRespond?: boolean;
  /** Response delay (ms) */
  responseDelay?: number;
}

type MessageHandler = (event: { data: string }) => void;
type OpenHandler = () => void;
type CloseHandler = (event: { code: number; reason: string }) => void;
type ErrorHandler = (event: { error: Error }) => void;

// =============================================================================
// MockWebSocket
// =============================================================================

export class MockWebSocket {
  // Static to track all instances for cleanup
  static instances: MockWebSocket[] = [];

  // Static constants matching real WebSocket API
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  // Instance constants (also needed by some code)
  readonly CONNECTING = 0;
  readonly OPEN = 1;
  readonly CLOSING = 2;
  readonly CLOSED = 3;

  // WebSocket-like properties
  url: string;
  readyState: WebSocketReadyState = READY_STATE.CONNECTING;

  // Event handlers (browser-style)
  onopen: OpenHandler | null = null;
  onclose: CloseHandler | null = null;
  onmessage: MessageHandler | null = null;
  onerror: ErrorHandler | null = null;

  // Internal tracking
  private sentMessages: string[] = [];
  private options: Required<MockWebSocketOptions>;
  private connectionTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(url: string, options: MockWebSocketOptions = {}) {
    this.url = url;
    this.options = {
      connectionDelay: -1, // -1 means don't auto-open (let test control it)
      autoRespond: false,
      responseDelay: 0,
      ...options,
    };

    MockWebSocket.instances.push(this);

    // Auto-connect after delay (if connectionDelay >= 0)
    if (this.options.connectionDelay === 0) {
      // Use microtask to allow event handlers to be set up first
      queueMicrotask(() => this.simulateOpen());
    } else if (this.options.connectionDelay > 0) {
      this.connectionTimer = setTimeout(() => {
        this.simulateOpen();
      }, this.options.connectionDelay);
    }
    // If connectionDelay < 0, don't auto-open - test will call simulateOpen()
  }

  // ===========================================================================
  // WebSocket API
  // ===========================================================================

  send(data: string): void {
    if (this.readyState !== READY_STATE.OPEN) {
      throw new Error('WebSocket is not open');
    }

    this.sentMessages.push(data);

    // Auto-respond if enabled
    if (this.options.autoRespond) {
      try {
        const request = JSON.parse(data) as RpcRequest;
        if (request.id && request.method) {
          const response: RpcResponse = {
            id: request.id,
            success: true,
            result: {},
          };

          if (this.options.responseDelay) {
            setTimeout(() => this.simulateMessage(response), this.options.responseDelay);
          } else {
            this.simulateMessage(response);
          }
        }
      } catch {
        // Not a valid request, ignore
      }
    }
  }

  close(code = 1000, reason = ''): void {
    if (this.readyState === READY_STATE.CLOSED) return;

    this.readyState = READY_STATE.CLOSING;

    // Simulate async close
    setTimeout(() => {
      this.readyState = READY_STATE.CLOSED;
      this.onclose?.({ code, reason });
    }, 0);
  }

  // ===========================================================================
  // Test Helpers
  // ===========================================================================

  /**
   * Simulate the connection opening
   */
  simulateOpen(): void {
    if (this.readyState === READY_STATE.CONNECTING) {
      this.readyState = READY_STATE.OPEN;
      this.onopen?.();
    }
  }

  /**
   * Simulate receiving a message from the server
   */
  simulateMessage(data: RpcResponse | RpcEvent | Record<string, unknown>): void {
    if (this.readyState === READY_STATE.OPEN) {
      this.onmessage?.({ data: JSON.stringify(data) });
    }
  }

  /**
   * Simulate a raw string message
   */
  simulateRawMessage(data: string): void {
    if (this.readyState === READY_STATE.OPEN) {
      this.onmessage?.({ data });
    }
  }

  /**
   * Simulate an error
   */
  simulateError(error: Error = new Error('Connection error')): void {
    this.onerror?.({ error });
  }

  /**
   * Simulate connection close from server
   */
  simulateClose(code = 1000, reason = ''): void {
    if (this.readyState === READY_STATE.CLOSED) return;

    this.readyState = READY_STATE.CLOSED;
    this.onclose?.({ code, reason });
  }

  /**
   * Get all messages sent through this socket
   */
  getSentMessages(): string[] {
    return [...this.sentMessages];
  }

  /**
   * Get sent messages parsed as RpcRequest objects
   */
  getSentRequests(): RpcRequest[] {
    return this.sentMessages
      .map((msg) => {
        try {
          return JSON.parse(msg) as RpcRequest;
        } catch {
          return null;
        }
      })
      .filter((req): req is RpcRequest => req !== null);
  }

  /**
   * Get the last sent request
   */
  getLastRequest(): RpcRequest | null {
    const requests = this.getSentRequests();
    return requests[requests.length - 1] ?? null;
  }

  /**
   * Clear sent message history
   */
  clearSentMessages(): void {
    this.sentMessages = [];
  }

  /**
   * Clean up timers
   */
  cleanup(): void {
    if (this.connectionTimer) {
      clearTimeout(this.connectionTimer);
      this.connectionTimer = null;
    }
  }

  // ===========================================================================
  // Static Helpers
  // ===========================================================================

  /**
   * Clear all instances
   */
  static clearInstances(): void {
    for (const instance of MockWebSocket.instances) {
      instance.cleanup();
    }
    MockWebSocket.instances = [];
  }

  /**
   * Get the most recent instance
   */
  static getLastInstance(): MockWebSocket | null {
    return MockWebSocket.instances[MockWebSocket.instances.length - 1] ?? null;
  }
}

// =============================================================================
// Global Mock Setup
// =============================================================================

/**
 * Install MockWebSocket as the global WebSocket
 */
export function installMockWebSocket(options: MockWebSocketOptions = {}): void {
  (globalThis as any).WebSocket = class extends MockWebSocket {
    constructor(url: string) {
      super(url, options);
    }
  };
}

/**
 * Remove MockWebSocket from global
 */
export function uninstallMockWebSocket(): void {
  delete (globalThis as any).WebSocket;
  MockWebSocket.clearInstances();
}
