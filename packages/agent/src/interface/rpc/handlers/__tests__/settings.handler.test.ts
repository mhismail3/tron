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

// Import mocked functions
import {
  getSettings,
  loadUserSettings,
  saveSettings,
  reloadSettings,
} from '@infrastructure/settings/index.js';

const mockGetSettings = vi.mocked(getSettings);
const mockLoadUserSettings = vi.mocked(loadUserSettings);
const mockSaveSettings = vi.mocked(saveSettings);
const mockReloadSettings = vi.mocked(reloadSettings);

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

    // Default settings mock
    mockGetSettings.mockReturnValue({
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
      },
      context: {
        compactor: {
          maxTokens: 25000,
          compactionThreshold: 0.85,
          targetTokens: 10000,
          preserveRecentCount: 5,
          charsPerToken: 4,
          forceAlways: false,
        },
        memory: { maxEntries: 1000 },
      },
    } as any);
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
        compaction: {
          preserveRecentTurns: 5,
          forceAlways: false,
        },
      });
    });

    it('should reflect custom values from settings', async () => {
      mockGetSettings.mockReturnValue({
        server: {
          defaultModel: 'claude-opus-4-6',
          defaultWorkspace: undefined,
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
        },
        context: {
          compactor: {
            maxTokens: 25000,
            compactionThreshold: 0.85,
            targetTokens: 10000,
            preserveRecentCount: 3,
            charsPerToken: 4,
            forceAlways: true,
          },
          memory: { maxEntries: 1000 },
        },
      } as any);

      const request: RpcRequest = {
        id: '2',
        method: 'settings.get',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.result).toEqual({
        defaultModel: 'claude-opus-4-6',
        defaultWorkspace: undefined,
        compaction: {
          preserveRecentTurns: 3,
          forceAlways: true,
        },
      });
    });

    it('should default forceAlways to false when undefined', async () => {
      mockGetSettings.mockReturnValue({
        server: {
          defaultModel: 'claude-sonnet-4-20250514',
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
        },
        context: {
          compactor: {
            maxTokens: 25000,
            compactionThreshold: 0.85,
            targetTokens: 10000,
            preserveRecentCount: 5,
            charsPerToken: 4,
            // forceAlways intentionally omitted
          },
          memory: { maxEntries: 1000 },
        },
      } as any);

      const request: RpcRequest = { id: '3', method: 'settings.get' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as any;

      expect(result.compaction.forceAlways).toBe(false);
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
