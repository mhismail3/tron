/**
 * @fileoverview Tests for Settings RPC Handlers
 *
 * Tests settings.get and settings.update handlers.
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { createSettingsHandlers } from '../settings.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

// Mock the settings module
vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(),
  loadUserSettings: vi.fn(),
  saveSettings: vi.fn(),
  reloadSettings: vi.fn(),
}));

vi.mock('@infrastructure/auth/unified.js', () => ({
  getAccountLabels: vi.fn(),
}));

// Import mocked functions
import {
  getSettings,
  loadUserSettings,
  saveSettings,
  reloadSettings,
} from '@infrastructure/settings/index.js';

import { getAccountLabels } from '@infrastructure/auth/unified.js';

const mockGetSettings = vi.mocked(getSettings);
const mockLoadUserSettings = vi.mocked(loadUserSettings);
const mockSaveSettings = vi.mocked(saveSettings);
const mockReloadSettings = vi.mocked(reloadSettings);
const mockGetAccountLabels = vi.mocked(getAccountLabels);

function createMockSettings(overrides: Record<string, any> = {}) {
  return {
    server: {
      defaultModel: 'claude-sonnet-4-20250514',
      defaultWorkspace: '/Users/test/projects',
      wsPort: 8080,
      healthPort: 8081,
      host: '0.0.0.0',
      heartbeatIntervalMs: 30000,
      sessionTimeoutMs: 1800000,
      maxConcurrentSessions: 10,
      sessionsDir: 'sessions',
      memoryDbPath: 'memory.db',
      defaultProvider: 'anthropic',
      transcription: {
        enabled: true,
        manageSidecar: true,
        baseUrl: 'http://127.0.0.1:8787',
        timeoutMs: 180000,
        cleanupMode: 'basic' as const,
        maxBytes: 25 * 1024 * 1024,
      },
      ...overrides.server,
    },
    context: {
      compactor: {
        maxTokens: 25000,
        compactionThreshold: 0.85,
        targetTokens: 10000,
        preserveRecentCount: 5,
        charsPerToken: 4,
        forceAlways: false,
        triggerTokenThreshold: 0.70,
        alertZoneThreshold: 0.50,
        defaultTurnFallback: 8,
        alertTurnFallback: 5,
        ...overrides.compactor,
      },
      memory: {
        maxEntries: 1000,
        ledger: { enabled: true },
        autoInject: { enabled: false, count: 5 },
        ...overrides.memory,
      },
      ...overrides.context,
    },
    tools: {
      web: {
        fetch: { timeoutMs: 30000 },
        cache: { ttlMs: 15 * 60 * 1000, maxEntries: 100 },
        ...overrides.web,
      },
      ...overrides.tools,
    },
  } as any;
}

describe('Settings Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createSettingsHandlers());

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
    };

    mockGetSettings.mockReturnValue(createMockSettings());
    mockGetAccountLabels.mockReturnValue([]);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('settings.get', () => {
    it('should return correct shape from default settings', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'settings.get',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        defaultModel: 'claude-sonnet-4-20250514',
        defaultWorkspace: '/Users/test/projects',
        maxConcurrentSessions: 10,
        compaction: {
          preserveRecentTurns: 5,
          forceAlways: false,
          triggerTokenThreshold: 0.70,
          alertZoneThreshold: 0.50,
          defaultTurnFallback: 8,
          alertTurnFallback: 5,
        },
        memory: {
          ledger: { enabled: true },
          autoInject: { enabled: false, count: 5 },
        },
        rules: {
          discoverStandaloneFiles: true,
        },
        tools: {
          web: {
            fetch: { timeoutMs: 30000 },
            cache: { ttlMs: 15 * 60 * 1000, maxEntries: 100 },
          },
        },
      });
    });

    it('should reflect custom values from settings', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        server: {
          defaultModel: 'claude-opus-4-6',
          defaultWorkspace: undefined,
        },
        compactor: {
          preserveRecentCount: 3,
          forceAlways: true,
          triggerTokenThreshold: 0.80,
          alertZoneThreshold: 0.60,
          defaultTurnFallback: 10,
          alertTurnFallback: 4,
        },
      }));

      const request: RpcRequest = {
        id: '2',
        method: 'settings.get',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.result).toEqual({
        defaultModel: 'claude-opus-4-6',
        defaultWorkspace: undefined,
        maxConcurrentSessions: 10,
        compaction: {
          preserveRecentTurns: 3,
          forceAlways: true,
          triggerTokenThreshold: 0.80,
          alertZoneThreshold: 0.60,
          defaultTurnFallback: 10,
          alertTurnFallback: 4,
        },
        memory: {
          ledger: { enabled: true },
          autoInject: { enabled: false, count: 5 },
        },
        rules: {
          discoverStandaloneFiles: true,
        },
        tools: {
          web: {
            fetch: { timeoutMs: 30000 },
            cache: { ttlMs: 15 * 60 * 1000, maxEntries: 100 },
          },
        },
      });
    });

    it('should default forceAlways to false when undefined', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        compactor: {
          forceAlways: undefined,
        },
      }));

      const request: RpcRequest = { id: '3', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.compaction.forceAlways).toBe(false);
    });

    it('should return memory ledger enabled', async () => {
      const request: RpcRequest = { id: '3a', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.memory.ledger.enabled).toBe(true);
    });

    it('should return memory ledger disabled when set', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        memory: { ledger: { enabled: false }, autoInject: { enabled: false, count: 5 } },
      }));

      const request: RpcRequest = { id: '3a2', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.memory.ledger.enabled).toBe(false);
    });

    it('should return memory autoInject settings', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        memory: { autoInject: { enabled: true, count: 7 } },
      }));

      const request: RpcRequest = { id: '3b', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.memory.autoInject.enabled).toBe(true);
      expect(result.memory.autoInject.count).toBe(7);
    });

    it('should return custom maxConcurrentSessions', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        server: { maxConcurrentSessions: 25 },
      }));

      const request: RpcRequest = { id: 'mcs-1', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      expect((response.result as any).maxConcurrentSessions).toBe(25);
    });

    it('should return anthropicAccounts when accounts exist', async () => {
      mockGetAccountLabels.mockReturnValue(['Personal', 'Work']);
      mockGetSettings.mockReturnValue(createMockSettings({
        server: { anthropicAccount: 'Work' },
      }));

      const request: RpcRequest = { id: 'acc-1', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.anthropicAccounts).toEqual(['Personal', 'Work']);
      expect(result.anthropicAccount).toBe('Work');
    });

    it('should omit anthropicAccounts when no accounts configured', async () => {
      mockGetAccountLabels.mockReturnValue([]);

      const request: RpcRequest = { id: 'acc-2', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.anthropicAccounts).toBeUndefined();
      expect(result.anthropicAccount).toBeUndefined();
    });

    it('should return web tool settings', async () => {
      mockGetSettings.mockReturnValue(createMockSettings({
        web: {
          fetch: { timeoutMs: 60000 },
          cache: { ttlMs: 30 * 60 * 1000, maxEntries: 200 },
        },
      }));

      const request: RpcRequest = { id: '4', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.tools.web.fetch.timeoutMs).toBe(60000);
      expect(result.tools.web.cache.ttlMs).toBe(30 * 60 * 1000);
      expect(result.tools.web.cache.maxEntries).toBe(200);
    });
  });

  describe('settings.update', () => {
    it('should write merged settings and reload cache', async () => {
      mockLoadUserSettings.mockReturnValue({
        server: { defaultModel: 'claude-sonnet-4-20250514' },
      });

      const request: RpcRequest = {
        id: '4',
        method: 'settings.update',
        params: {
          settings: {
            context: {
              compactor: { forceAlways: true },
            },
          },
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSaveSettings).toHaveBeenCalledOnce();
      expect(mockReloadSettings).toHaveBeenCalledOnce();

      // Check the saved value is a deep merge
      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.server.defaultModel).toBe('claude-sonnet-4-20250514');
      expect(savedArg.context.compactor.forceAlways).toBe(true);
    });

    it('should deep merge without clobbering unrelated keys', async () => {
      mockLoadUserSettings.mockReturnValue({
        server: { defaultModel: 'claude-opus-4-6', defaultWorkspace: '/home/user/code' },
        context: { compactor: { preserveRecentCount: 3, forceAlways: false } },
      });

      const request: RpcRequest = {
        id: '5',
        method: 'settings.update',
        params: {
          settings: {
            context: { compactor: { forceAlways: true } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      // Existing values preserved
      expect(savedArg.server.defaultModel).toBe('claude-opus-4-6');
      expect(savedArg.server.defaultWorkspace).toBe('/home/user/code');
      expect(savedArg.context.compactor.preserveRecentCount).toBe(3);
      // Updated value applied
      expect(savedArg.context.compactor.forceAlways).toBe(true);
    });

    it('should create settings from empty when file does not exist', async () => {
      mockLoadUserSettings.mockReturnValue(null);

      const request: RpcRequest = {
        id: '6',
        method: 'settings.update',
        params: {
          settings: {
            server: { defaultModel: 'claude-opus-4-6' },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.server.defaultModel).toBe('claude-opus-4-6');
    });

    it('should reject when settings param is missing', async () => {
      const request: RpcRequest = {
        id: '7',
        method: 'settings.update',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should update web tool settings', async () => {
      mockLoadUserSettings.mockReturnValue({
        tools: { web: { fetch: { timeoutMs: 30000 } } },
      });

      const request: RpcRequest = {
        id: '8',
        method: 'settings.update',
        params: {
          settings: {
            tools: { web: { fetch: { timeoutMs: 60000 } } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.tools.web.fetch.timeoutMs).toBe(60000);
    });

    it('should update maxConcurrentSessions', async () => {
      mockLoadUserSettings.mockReturnValue({
        server: { maxConcurrentSessions: 10 },
      });

      const request: RpcRequest = {
        id: 'mcs-2',
        method: 'settings.update',
        params: {
          settings: {
            server: { maxConcurrentSessions: 20 },
          },
        },
      };

      await registry.dispatch(request, mockContext);
      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.server.maxConcurrentSessions).toBe(20);
    });

    it('should update compaction trigger settings', async () => {
      mockLoadUserSettings.mockReturnValue({
        context: { compactor: { triggerTokenThreshold: 0.70 } },
      });

      const request: RpcRequest = {
        id: '9',
        method: 'settings.update',
        params: {
          settings: {
            context: { compactor: { triggerTokenThreshold: 0.85 } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.context.compactor.triggerTokenThreshold).toBe(0.85);
    });

    it('should update memory autoInject enabled', async () => {
      mockLoadUserSettings.mockReturnValue({
        context: { memory: { autoInject: { enabled: false, count: 5 } } },
      });

      const request: RpcRequest = {
        id: '10',
        method: 'settings.update',
        params: {
          settings: {
            context: { memory: { autoInject: { enabled: true } } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.context.memory.autoInject.enabled).toBe(true);
      expect(savedArg.context.memory.autoInject.count).toBe(5);
    });

    it('should update memory ledger enabled', async () => {
      mockLoadUserSettings.mockReturnValue({
        context: { memory: { ledger: { enabled: true } } },
      });

      const request: RpcRequest = {
        id: '10b',
        method: 'settings.update',
        params: {
          settings: {
            context: { memory: { ledger: { enabled: false } } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.context.memory.ledger.enabled).toBe(false);
    });

    it('should update anthropicAccount', async () => {
      mockLoadUserSettings.mockReturnValue({
        server: { defaultModel: 'claude-opus-4-6' },
      });

      const request: RpcRequest = {
        id: 'acc-update',
        method: 'settings.update',
        params: {
          settings: {
            server: { anthropicAccount: 'Work' },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.server.anthropicAccount).toBe('Work');
      expect(savedArg.server.defaultModel).toBe('claude-opus-4-6');
    });

    it('should update memory autoInject count', async () => {
      mockLoadUserSettings.mockReturnValue({
        context: { memory: { autoInject: { enabled: true, count: 5 } } },
      });

      const request: RpcRequest = {
        id: '11',
        method: 'settings.update',
        params: {
          settings: {
            context: { memory: { autoInject: { count: 3 } } },
          },
        },
      };

      await registry.dispatch(request, mockContext);

      const savedArg = mockSaveSettings.mock.calls[0]![0] as any;
      expect(savedArg.context.memory.autoInject.count).toBe(3);
      expect(savedArg.context.memory.autoInject.enabled).toBe(true);
    });
  });

  describe('createSettingsHandlers', () => {
    it('should create two handler registrations', () => {
      const handlers = createSettingsHandlers();
      expect(handlers).toHaveLength(2);
      expect(handlers[0]?.method).toBe('settings.get');
      expect(handlers[1]?.method).toBe('settings.update');
    });
  });
});
