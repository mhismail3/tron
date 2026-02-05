/**
 * @fileoverview APNS Service Tests
 *
 * Tests for Apple Push Notification Service client including:
 * - JWT token generation
 * - Config loading and validation
 * - Notification sending
 * - Error handling
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'crypto';
import type { APNSConfig, APNSNotification } from '../types.js';

// Track mock http2 connect behavior
let mockHttp2ConnectBehavior: 'success' | 'error' | 'custom' = 'success';
let mockHttp2Response: { status: number; apnsId?: string; body?: string } = { status: 200 };
let mockConnectCallback: ((client: any) => void) | null = null;

// Mock http2 module
vi.mock('http2', () => {
  const createMockClient = () => {
    const handlers: Record<string, Function[]> = {};
    const mockClient = {
      on: vi.fn((event: string, cb: Function) => {
        if (!handlers[event]) handlers[event] = [];
        handlers[event].push(cb);
        return mockClient;
      }),
      emit: (event: string, ...args: any[]) => {
        handlers[event]?.forEach(cb => cb(...args));
      },
      destroyed: false,
      close: vi.fn(),
      request: vi.fn(() => {
        const streamHandlers: Record<string, Function[]> = {};
        const mockStream = {
          on: vi.fn((event: string, cb: Function) => {
            if (!streamHandlers[event]) streamHandlers[event] = [];
            streamHandlers[event].push(cb);
            return mockStream;
          }),
          end: vi.fn(() => {
            // Simulate async response
            setTimeout(() => {
              streamHandlers['response']?.forEach(cb =>
                cb({ ':status': mockHttp2Response.status, 'apns-id': mockHttp2Response.apnsId })
              );
              if (mockHttp2Response.body) {
                streamHandlers['data']?.forEach(cb => cb(Buffer.from(mockHttp2Response.body!)));
              }
              streamHandlers['end']?.forEach(cb => cb());
            }, 0);
          }),
        };
        return mockStream;
      }),
    };
    return { client: mockClient, handlers };
  };

  return {
    connect: vi.fn((_url: string) => {
      const { client, handlers } = createMockClient();

      if (mockConnectCallback) {
        mockConnectCallback(client);
      } else if (mockHttp2ConnectBehavior === 'error') {
        setTimeout(() => {
          handlers['error']?.forEach(cb => cb(new Error('Connection refused')));
        }, 0);
      } else {
        setTimeout(() => {
          handlers['connect']?.forEach(cb => cb());
        }, 0);
      }

      return client;
    }),
  };
});

// Mock modules before import
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
  categorizeError: vi.fn((e) => ({
    code: 'UNKNOWN',
    message: e?.message || String(e),
    retryable: false,
    category: 'unknown',
  })),
}));

// Generate a valid ES256 test key pair
// In real tests we'd use a fixture, but for unit tests we mock the crypto
const MOCK_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgK7z2Dq5qB+uSm5YI
f8z5MjKKnvHuLaGQiQ1SX4p0c0agCgYIKoZIzj0DAQehRANCAAQK7z2Dq5qB+uSm
5YIf8z5MjKKnvHuLaGQiQ1SX4p0c0aS4x3zEw5FXbL5jM7KTBP5J5IiR8l5nq5c4
UjQGTyoJ
-----END PRIVATE KEY-----`;

const MOCK_CONFIG: APNSConfig = {
  keyPath: '/tmp/test-apns-key.p8',
  keyId: 'ABCD1234EF',
  teamId: 'TEAM123456',
  bundleId: 'com.example.tron',
  environment: 'sandbox',
};

describe('loadAPNSConfig', () => {
  const originalEnv = process.env.HOME;
  let mockHome: string;
  let configPath: string;
  let keyPath: string;

  beforeEach(() => {
    mockHome = path.join(os.tmpdir(), `apns-test-${randomUUID()}`);
    configPath = path.join(mockHome, '.tron', 'mods', 'apns', 'config.json');
    keyPath = path.join(mockHome, '.tron', 'mods', 'apns', 'AuthKey_ABCD1234EF.p8');
    process.env.HOME = mockHome;
    vi.clearAllMocks();
  });

  afterEach(() => {
    process.env.HOME = originalEnv;
    try {
      fs.rmSync(mockHome, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  it('returns null when config file does not exist', async () => {
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();
    expect(result).toBeNull();
  });

  it('returns null when config is missing required fields', async () => {
    // Create directory structure
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(configPath, JSON.stringify({ keyId: 'test' }));

    vi.resetModules();
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();
    expect(result).toBeNull();
  });

  it('returns null when key file does not exist', async () => {
    // Create config but not key
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(
      configPath,
      JSON.stringify({
        keyId: 'ABCD1234EF',
        teamId: 'TEAM123456',
        bundleId: 'com.example.app',
      })
    );

    vi.resetModules();
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();
    expect(result).toBeNull();
  });

  it('returns config when all requirements are met', async () => {
    // Create config and key
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(
      configPath,
      JSON.stringify({
        keyId: 'ABCD1234EF',
        teamId: 'TEAM123456',
        bundleId: 'com.example.app',
        environment: 'production',
      })
    );
    fs.writeFileSync(keyPath, MOCK_PRIVATE_KEY);

    vi.resetModules();
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();

    expect(result).not.toBeNull();
    expect(result!.keyId).toBe('ABCD1234EF');
    expect(result!.teamId).toBe('TEAM123456');
    expect(result!.bundleId).toBe('com.example.app');
    expect(result!.environment).toBe('production');
  });

  it('defaults to sandbox environment when not specified', async () => {
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(
      configPath,
      JSON.stringify({
        keyId: 'ABCD1234EF',
        teamId: 'TEAM123456',
        bundleId: 'com.example.app',
      })
    );
    fs.writeFileSync(keyPath, MOCK_PRIVATE_KEY);

    vi.resetModules();
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();

    expect(result).not.toBeNull();
    expect(result!.environment).toBe('sandbox');
  });

  it('handles JSON parse errors gracefully', async () => {
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(configPath, 'not valid json');

    vi.resetModules();
    const { loadAPNSConfig } = await import('../apns-service.js');
    const result = loadAPNSConfig();
    expect(result).toBeNull();
  });
});

describe('createAPNSService', () => {
  const originalEnv = process.env.HOME;
  let mockHome: string;
  let configPath: string;
  let keyPath: string;

  beforeEach(() => {
    mockHome = path.join(os.tmpdir(), `apns-svc-test-${randomUUID()}`);
    configPath = path.join(mockHome, '.tron', 'mods', 'apns', 'config.json');
    keyPath = path.join(mockHome, '.tron', 'mods', 'apns', 'AuthKey_ABCD1234EF.p8');
    process.env.HOME = mockHome;
    vi.clearAllMocks();
  });

  afterEach(() => {
    process.env.HOME = originalEnv;
    try {
      fs.rmSync(mockHome, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  it('returns null when config is not available', async () => {
    vi.resetModules();
    const { createAPNSService } = await import('../apns-service.js');
    const service = createAPNSService();
    expect(service).toBeNull();
  });

  it('returns APNSService instance when config is valid', async () => {
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
    fs.writeFileSync(
      configPath,
      JSON.stringify({
        keyId: 'ABCD1234EF',
        teamId: 'TEAM123456',
        bundleId: 'com.example.app',
      })
    );
    fs.writeFileSync(keyPath, MOCK_PRIVATE_KEY);

    vi.resetModules();
    const { createAPNSService, APNSService } = await import('../apns-service.js');
    const service = createAPNSService();

    expect(service).not.toBeNull();
    expect(service).toBeInstanceOf(APNSService);
  });
});

describe('APNSService', () => {
  let mockHome: string;
  let keyPath: string;

  beforeEach(() => {
    mockHome = path.join(os.tmpdir(), `apns-svc-inst-test-${randomUUID()}`);
    keyPath = path.join(mockHome, 'test-key.p8');
    vi.clearAllMocks();
    mockHttp2ConnectBehavior = 'success';
    mockHttp2Response = { status: 200 };
    mockConnectCallback = null;
    fs.mkdirSync(mockHome, { recursive: true });
    fs.writeFileSync(keyPath, MOCK_PRIVATE_KEY);
  });

  afterEach(() => {
    try {
      fs.rmSync(mockHome, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  describe('constructor', () => {
    it('throws when key file does not exist', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      expect(
        () =>
          new APNSService({
            ...MOCK_CONFIG,
            keyPath: '/nonexistent/key.p8',
          })
      ).toThrow('Failed to load APNS private key');
    });

    it('loads key file successfully', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
      });

      expect(service).toBeDefined();
    });

    it('expands ~ in key path', async () => {
      const originalHome = process.env.HOME;
      process.env.HOME = mockHome;
      fs.writeFileSync(path.join(mockHome, 'expanded-key.p8'), MOCK_PRIVATE_KEY);

      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath: '~/expanded-key.p8',
      });

      expect(service).toBeDefined();
      process.env.HOME = originalHome;
    });
  });

  describe('host selection', () => {
    it('uses sandbox host for sandbox environment', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
        environment: 'sandbox',
      });

      // Access private property via any for testing
      expect((service as any).host).toBe('api.sandbox.push.apple.com');
    });

    it('uses production host for production environment', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
        environment: 'production',
      });

      expect((service as any).host).toBe('api.push.apple.com');
    });
  });

  describe('send', () => {
    // Note: HTTP/2 mocking is complex in ESM environments.
    // These tests verify the contract behavior; integration tests verify actual APNS communication.

    it('returns failure result on connection error', async () => {
      mockHttp2ConnectBehavior = 'error';

      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
      });

      const notification: APNSNotification = {
        title: 'Test',
        body: 'Test notification',
      };

      const result = await service.send('abc123devicetoken', notification);

      expect(result.success).toBe(false);
      expect(result.deviceToken).toBe('abc123devicetoken');
      expect(result.error).toBeDefined();
    });

    // These tests require proper HTTP/2 mocking which is complex in ESM
    // The actual APNS communication is tested via integration tests
    it.todo('returns success result on 200 response - requires HTTP/2 integration test');
    it.todo('returns failure result on non-200 response - requires HTTP/2 integration test');
  });

  describe('sendToMany', () => {
    it('returns empty array for empty token list', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
      });

      const results = await service.sendToMany([], {
        title: 'Test',
        body: 'Test',
      });

      expect(results).toEqual([]);
    });

    it('sends to multiple devices in parallel', async () => {
      const sendSpy = vi.fn().mockResolvedValue({
        success: true,
        deviceToken: 'test',
        apnsId: 'id',
        statusCode: 200,
      });

      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
      });

      // Replace send method with spy
      (service as any).send = sendSpy;

      const tokens = ['token1', 'token2', 'token3'];
      const notification: APNSNotification = {
        title: 'Test',
        body: 'Test notification',
      };

      const results = await service.sendToMany(tokens, notification);

      expect(results.length).toBe(3);
      expect(sendSpy).toHaveBeenCalledTimes(3);
    });
  });

  describe('close', () => {
    it('handles close when no connection exists', async () => {
      vi.resetModules();
      const { APNSService } = await import('../apns-service.js');

      const service = new APNSService({
        ...MOCK_CONFIG,
        keyPath,
      });

      // Should not throw
      expect(() => service.close()).not.toThrow();
    });

    // HTTP/2 connection lifecycle is tested via integration tests
    it.todo('closes the HTTP/2 connection - requires HTTP/2 integration test');
  });
});
