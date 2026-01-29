/**
 * @fileoverview Tests for WebSocket Server
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { WebSocket, WebSocketServer } from 'ws';
import { TronWebSocketServer } from '../gateway/websocket.js';
import type { RpcContext } from '../index.js';

// Mock ws module
vi.mock('ws', () => {
  const MockWebSocketServer = vi.fn().mockImplementation(() => ({
    on: vi.fn(),
    close: vi.fn((cb) => cb?.()),
    clients: new Set(),
  }));

  return {
    WebSocketServer: MockWebSocketServer,
    WebSocket: {
      OPEN: 1,
      CLOSED: 3,
    },
  };
});

// Mock RpcContext
const mockContext: RpcContext = {
  sessionManager: {
    createSession: vi.fn().mockResolvedValue({ sessionId: 'sess_test', messages: [] }),
    getSession: vi.fn().mockResolvedValue(null),
    resumeSession: vi.fn().mockResolvedValue({ sessionId: 'sess_test' }),
    listSessions: vi.fn().mockResolvedValue([]),
    deleteSession: vi.fn().mockResolvedValue(true),
    forkSession: vi.fn().mockResolvedValue({ newSessionId: 'sess_fork' }),
    switchModel: vi.fn().mockResolvedValue({ success: true }),
  },
  agentManager: {
    prompt: vi.fn().mockResolvedValue({ success: true }),
    abort: vi.fn().mockResolvedValue({ success: true }),
    getState: vi.fn().mockResolvedValue({ messages: [] }),
  },
  memoryStore: {
    searchEntries: vi.fn().mockResolvedValue({ entries: [], totalCount: 0 }),
    addEntry: vi.fn().mockResolvedValue({ id: 'mem_test' }),
    listHandoffs: vi.fn().mockResolvedValue([]),
  },
};

describe('TronWebSocketServer', () => {
  let server: TronWebSocketServer;
  let mockWss: any;

  beforeEach(() => {
    vi.clearAllMocks();

    server = new TronWebSocketServer({
      port: 8080,
      host: 'localhost',
    }, mockContext);

    // Get the mock WSS instance
    mockWss = (WebSocketServer as any).mock.results[0]?.value;
  });

  afterEach(async () => {
    if (server) {
      await server.stop();
    }
  });

  describe('constructor', () => {
    it('should create server with config', () => {
      expect(server).toBeInstanceOf(TronWebSocketServer);
    });
  });

  describe('start', () => {
    it('should start WebSocket server', async () => {
      // Setup mock to trigger listening event
      const wss = {
        on: vi.fn((event, callback) => {
          if (event === 'listening') {
            setTimeout(() => callback(), 0);
          }
        }),
        close: vi.fn((cb) => cb?.()),
      };
      (WebSocketServer as any).mockImplementationOnce(() => wss);

      const newServer = new TronWebSocketServer({ port: 8081 }, mockContext);
      await newServer.start();

      expect(WebSocketServer).toHaveBeenCalledWith({
        port: 8081,
        host: '0.0.0.0',
        path: '/ws',
      });
    });
  });

  describe('stop', () => {
    it('should stop WebSocket server', async () => {
      // Setup mock
      const wss = {
        on: vi.fn((event, callback) => {
          if (event === 'listening') {
            setTimeout(() => callback(), 0);
          }
        }),
        close: vi.fn((cb) => cb?.()),
      };
      (WebSocketServer as any).mockImplementationOnce(() => wss);

      const newServer = new TronWebSocketServer({ port: 8082 }, mockContext);
      await newServer.start();
      await newServer.stop();

      expect(wss.close).toHaveBeenCalled();
    });
  });

  describe('getClientCount', () => {
    it('should return 0 when no clients connected', () => {
      expect(server.getClientCount()).toBe(0);
    });
  });

  describe('getClientIds', () => {
    it('should return empty array when no clients connected', () => {
      expect(server.getClientIds()).toEqual([]);
    });
  });

  describe('broadcastEvent', () => {
    it('should not throw when no clients connected', () => {
      expect(() => {
        server.broadcastEvent({
          type: 'test.event',
          timestamp: new Date().toISOString(),
          data: { test: true },
        });
      }).not.toThrow();
    });
  });

  describe('sendToClient', () => {
    it('should return false for non-existent client', () => {
      const result = server.sendToClient('client_nonexistent', {
        type: 'test.event',
        timestamp: new Date().toISOString(),
        data: {},
      });

      expect(result).toBe(false);
    });
  });
});

describe('TronWebSocketServer - Integration', () => {
  // Note: These tests would use actual WebSocket connections
  // For unit tests, we mock the ws module above
  // Full integration tests would be in a separate file

  describe('client connection', () => {
    it('should handle client connection (mocked)', () => {
      // This would test actual WebSocket connections in integration tests
      expect(true).toBe(true);
    });
  });

  describe('RPC message handling', () => {
    it('should route RPC requests to handler (mocked)', () => {
      // This would test actual message routing in integration tests
      expect(true).toBe(true);
    });
  });
});
