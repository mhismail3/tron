/**
 * @fileoverview ModelController Unit Tests (TDD)
 *
 * Tests for the ModelController class extracted from EventStoreOrchestrator.
 *
 * Contract:
 * 1. Validate session exists in event store
 * 2. Validate session is not processing (if active)
 * 3. Append config.model_switch event (linearized for active, direct for inactive)
 * 4. Persist model to database via eventStore.updateLatestModel
 * 5. Update active session model and provider type
 * 6. Switch agent model with correct auth
 */
import { describe, it, expect, beforeEach, vi, type Mock } from 'vitest';
import { ModelController, createModelController, type ModelControllerConfig } from '../model-controller.js';
import type { ActiveSession } from '../types.js';
import type { SessionId } from '../../events/types.js';

// =============================================================================
// Test Fixtures
// =============================================================================

/**
 * Create a mock ActiveSession for testing.
 */
function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  const mockAgent = {
    switchModel: vi.fn(),
  };

  const mockSessionContext = {
    isProcessing: vi.fn().mockReturnValue(false),
    appendEvent: vi.fn().mockResolvedValue({ id: 'evt_mock' }),
    updateProviderTypeForModel: vi.fn(),
  };

  return {
    sessionId: 'sess_test123',
    agent: mockAgent as any,
    sessionContext: mockSessionContext as any,
    model: 'claude-sonnet-4-20250514',
    ...overrides,
  } as unknown as ActiveSession;
}

/**
 * Create a mock ModelControllerConfig for testing.
 */
function createMockConfig(overrides: Partial<ModelControllerConfig> = {}): ModelControllerConfig {
  const mockEventStore = {
    getSession: vi.fn().mockResolvedValue({
      id: 'sess_test123',
      latestModel: 'claude-sonnet-4-20250514',
    }),
    append: vi.fn().mockResolvedValue({ id: 'evt_direct' }),
    updateLatestModel: vi.fn().mockResolvedValue(undefined),
  };

  const mockAuthProvider = {
    getAuthForProvider: vi.fn().mockResolvedValue({
      type: 'api_key',
      apiKey: 'test-key',
    }),
  };

  return {
    eventStore: mockEventStore as any,
    authProvider: mockAuthProvider as any,
    getActiveSession: vi.fn().mockReturnValue(undefined),
    normalizeToUnifiedAuth: vi.fn().mockImplementation((auth) => auth),
    ...overrides,
  };
}

// =============================================================================
// Unit Tests: Factory Function
// =============================================================================

describe('createModelController', () => {
  it('creates a ModelController instance', () => {
    const config = createMockConfig();
    const controller = createModelController(config);

    expect(controller).toBeInstanceOf(ModelController);
  });
});

// =============================================================================
// Unit Tests: ModelController.switchModel()
// =============================================================================

describe('ModelController', () => {
  let controller: ModelController;
  let config: ModelControllerConfig;

  beforeEach(() => {
    config = createMockConfig();
    controller = new ModelController(config);
  });

  describe('switchModel() - Validation', () => {
    it('throws if session not found in event store', async () => {
      (config.eventStore.getSession as Mock).mockResolvedValue(null);

      await expect(controller.switchModel('sess_unknown', 'gpt-4o'))
        .rejects.toThrow('Session not found: sess_unknown');
    });

    it('throws if active session is processing', async () => {
      const active = createMockActiveSession();
      (active.sessionContext.isProcessing as Mock).mockReturnValue(true);
      (config.getActiveSession as Mock).mockReturnValue(active);

      await expect(controller.switchModel('sess_test123', 'gpt-4o'))
        .rejects.toThrow('Cannot switch model while agent is processing');
    });
  });

  describe('switchModel() - Event Persistence', () => {
    it('appends config.model_switch event via sessionContext for active session', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'config.model_switch',
        expect.objectContaining({
          previousModel: 'claude-sonnet-4-20250514',
          newModel: 'gpt-4o',
        })
      );
    });

    it('appends config.model_switch event directly for inactive session', async () => {
      (config.getActiveSession as Mock).mockReturnValue(undefined);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(config.eventStore.append).toHaveBeenCalledWith({
        sessionId: 'sess_test123',
        type: 'config.model_switch',
        payload: expect.objectContaining({
          previousModel: 'claude-sonnet-4-20250514',
          newModel: 'gpt-4o',
        }),
      });
    });
  });

  describe('switchModel() - Database Persistence', () => {
    it('persists model to database via updateLatestModel', async () => {
      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(config.eventStore.updateLatestModel).toHaveBeenCalledWith(
        'sess_test123',
        'gpt-4o'
      );
    });
  });

  describe('switchModel() - Active Session Updates', () => {
    it('updates active session model property', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(active.model).toBe('gpt-4o');
    });

    it('updates provider type for token normalization', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(active.sessionContext.updateProviderTypeForModel).toHaveBeenCalledWith('gpt-4o');
    });

    it('loads auth for new model', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(config.authProvider.getAuthForProvider).toHaveBeenCalledWith('gpt-4o');
    });

    it('switches agent model with normalized auth', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);
      (config.authProvider.getAuthForProvider as Mock).mockResolvedValue({
        type: 'api_key',
        apiKey: 'openai-key',
      });

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(active.agent.switchModel).toHaveBeenCalledWith(
        'gpt-4o',
        undefined,
        expect.objectContaining({ type: 'api_key' })
      );
    });

    it('preserves endpoint for Google models', async () => {
      const active = createMockActiveSession();
      (config.getActiveSession as Mock).mockReturnValue(active);
      (config.authProvider.getAuthForProvider as Mock).mockResolvedValue({
        type: 'oauth',
        accessToken: 'google-token',
        endpoint: 'https://generativelanguage.googleapis.com',
      });

      await controller.switchModel('sess_test123', 'gemini-2.5-pro');

      expect(active.agent.switchModel).toHaveBeenCalledWith(
        'gemini-2.5-pro',
        undefined,
        expect.objectContaining({
          endpoint: 'https://generativelanguage.googleapis.com',
        })
      );
    });
  });

  describe('switchModel() - Return Value', () => {
    it('returns previous and new model', async () => {
      const result = await controller.switchModel('sess_test123', 'gpt-4o');

      expect(result).toEqual({
        previousModel: 'claude-sonnet-4-20250514',
        newModel: 'gpt-4o',
      });
    });
  });

  describe('switchModel() - No Active Session', () => {
    it('skips agent updates when session is not active', async () => {
      (config.getActiveSession as Mock).mockReturnValue(undefined);

      await controller.switchModel('sess_test123', 'gpt-4o');

      // Should not attempt to load auth or switch agent model
      expect(config.authProvider.getAuthForProvider).not.toHaveBeenCalled();
    });

    it('still persists to database when session is not active', async () => {
      (config.getActiveSession as Mock).mockReturnValue(undefined);

      await controller.switchModel('sess_test123', 'gpt-4o');

      expect(config.eventStore.updateLatestModel).toHaveBeenCalledWith(
        'sess_test123',
        'gpt-4o'
      );
    });
  });
});
