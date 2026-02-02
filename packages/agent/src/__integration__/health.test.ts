/**
 * @fileoverview Tests for Health Server
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as http from 'http';
import { HealthServer } from '@interface/gateway/health.js';
import type { EventStoreOrchestrator } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';

// Mock http module
vi.mock('http', () => ({
  createServer: vi.fn(() => ({
    listen: vi.fn((port, host, callback) => callback?.()),
    close: vi.fn((callback) => callback?.()),
    on: vi.fn(),
  })),
}));

// Mock orchestrator
const mockOrchestrator = {
  getHealth: vi.fn().mockReturnValue({
    status: 'healthy',
    activeSessions: 2,
    processingSessions: 1,
    uptime: 1000,
  }),
} as unknown as EventStoreOrchestrator;

describe('HealthServer', () => {
  let server: HealthServer;

  beforeEach(() => {
    vi.clearAllMocks();

    server = new HealthServer({
      port: 8081,
      host: 'localhost',
    });
  });

  afterEach(async () => {
    await server.stop();
  });

  describe('constructor', () => {
    it('should create server with config', () => {
      expect(server).toBeInstanceOf(HealthServer);
    });
  });

  describe('setEventStoreOrchestrator', () => {
    it('should set orchestrator reference', () => {
      expect(() => server.setEventStoreOrchestrator(mockOrchestrator)).not.toThrow();
    });
  });

  describe('setWsClientCount', () => {
    it('should set WebSocket client count function', () => {
      expect(() => server.setWsClientCount(() => 5)).not.toThrow();
    });
  });

  describe('start', () => {
    it('should start HTTP server', async () => {
      await server.start();

      expect(http.createServer).toHaveBeenCalled();
    });
  });

  describe('stop', () => {
    it('should stop HTTP server', async () => {
      await server.start();
      await server.stop();

      // Should not throw
      expect(true).toBe(true);
    });

    it('should handle stopping when not started', async () => {
      await server.stop();
      // Should not throw
      expect(true).toBe(true);
    });
  });
});

describe('HealthServer - Request Handling', () => {
  let server: HealthServer;
  let mockReq: Partial<http.IncomingMessage>;
  let mockRes: Partial<http.ServerResponse>;
  let requestHandler: (req: http.IncomingMessage, res: http.ServerResponse) => void;

  beforeEach(() => {
    vi.clearAllMocks();

    // Capture the request handler
    (http.createServer as any).mockImplementation((handler: any) => {
      requestHandler = handler;
      return {
        listen: vi.fn((port, host, callback) => callback?.()),
        close: vi.fn((callback) => callback?.()),
        on: vi.fn(),
      };
    });

    server = new HealthServer({ port: 8081 });
    server.setEventStoreOrchestrator(mockOrchestrator);
    server.setWsClientCount(() => 3);

    mockReq = {
      method: 'GET',
      url: '/health',
      headers: { host: 'localhost:8081' },
    };

    mockRes = {
      setHeader: vi.fn(),
      writeHead: vi.fn(),
      end: vi.fn(),
    };
  });

  afterEach(async () => {
    await server.stop();
  });

  describe('/health endpoint', () => {
    it('should return health status', async () => {
      await server.start();

      mockReq.url = '/health';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
      expect(mockRes.end).toHaveBeenCalled();
    });

    it('should also respond to /healthz', async () => {
      await server.start();

      mockReq.url = '/healthz';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(200, expect.any(Object));
    });
  });

  describe('/ready endpoint', () => {
    it('should return ready status', async () => {
      await server.start();

      mockReq.url = '/ready';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'application/json' });
    });

    it('should return not ready when no orchestrator', async () => {
      const noOrchestratorServer = new HealthServer({ port: 8082 });

      (http.createServer as any).mockImplementation((handler: any) => {
        requestHandler = handler;
        return {
          listen: vi.fn((port, host, callback) => callback?.()),
          close: vi.fn((callback) => callback?.()),
          on: vi.fn(),
        };
      });

      await noOrchestratorServer.start();

      mockReq.url = '/ready';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(503, { 'Content-Type': 'application/json' });

      await noOrchestratorServer.stop();
    });
  });

  describe('/metrics endpoint', () => {
    it('should return Prometheus metrics', async () => {
      await server.start();

      mockReq.url = '/metrics';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(200, { 'Content-Type': 'text/plain' });
      expect(mockRes.end).toHaveBeenCalledWith(expect.stringContaining('tron_uptime_seconds'));
    });
  });

  describe('unknown endpoint', () => {
    it('should return 404', async () => {
      await server.start();

      mockReq.url = '/unknown';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(404, { 'Content-Type': 'application/json' });
    });
  });

  describe('OPTIONS request', () => {
    it('should handle CORS preflight', async () => {
      await server.start();

      mockReq.method = 'OPTIONS';
      requestHandler(mockReq as http.IncomingMessage, mockRes as http.ServerResponse);

      expect(mockRes.writeHead).toHaveBeenCalledWith(204);
    });
  });
});
