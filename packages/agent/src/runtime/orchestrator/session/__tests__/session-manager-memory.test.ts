/**
 * @fileoverview Session Manager Memory Injection Tests
 *
 * Tests that workspace memory (lessons from past sessions) is correctly
 * loaded and injected into agent context during session creation and resumption.
 * Memory loading is conditional on settings (context.memory.autoInject.enabled).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(),
    debug: vi.fn(),
    trace: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
  categorizeError: vi.fn(),
  LogErrorCategory: {},
}));

vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(),
}));

vi.mock('@context/loader.js', () => ({
  ContextLoader: vi.fn(),
}));

vi.mock('@context/rules-tracker.js', () => ({
  createRulesTracker: vi.fn(),
}));

vi.mock('@capabilities/extensions/skills/skill-tracker.js', () => ({
  createSkillTracker: vi.fn(),
}));

vi.mock('@capabilities/tools/subagent/subagent-tracker.js', () => ({
  createSubAgentTracker: vi.fn(),
}));

vi.mock('@capabilities/todos/todo-tracker.js', () => ({
  createTodoTracker: vi.fn(),
}));

vi.mock('../tracker-reconstructor.js', () => ({
  createTrackerReconstructor: vi.fn(),
}));

vi.mock('../session-context.js', () => ({
  createSessionContext: vi.fn(),
}));

vi.mock('../../operations/worktree-ops.js', () => ({
  buildWorktreeInfo: vi.fn(),
}));

vi.mock('@llm/providers/factory.js', () => ({
  detectProviderFromModel: vi.fn(),
}));

import { SessionManager, type SessionManagerConfig } from '../session-manager.js';
import { categorizeError } from '@infrastructure/logging/index.js';
import { getSettings } from '@infrastructure/settings/index.js';
import { ContextLoader } from '@context/loader.js';
import { detectProviderFromModel } from '@llm/providers/factory.js';
import { createRulesTracker } from '@context/rules-tracker.js';
import { createSkillTracker } from '@capabilities/extensions/skills/skill-tracker.js';
import { createSubAgentTracker } from '@capabilities/tools/subagent/subagent-tracker.js';
import { createTodoTracker } from '@capabilities/todos/todo-tracker.js';
import { createTrackerReconstructor } from '../tracker-reconstructor.js';
import { createSessionContext } from '../session-context.js';
import { buildWorktreeInfo } from '../../operations/worktree-ops.js';
import type { ActiveSession } from '../../types.js';
import { DEFAULT_SETTINGS } from '@infrastructure/settings/defaults.js';

const mockGetSettings = vi.mocked(getSettings);

// Helper to create settings with autoInject overrides
function createSettingsWithAutoInject(overrides: { enabled?: boolean; count?: number } = {}) {
  return {
    ...DEFAULT_SETTINGS,
    context: {
      ...DEFAULT_SETTINGS.context,
      memory: {
        ...DEFAULT_SETTINGS.context.memory,
        autoInject: {
          enabled: overrides.enabled ?? false,
          count: overrides.count ?? 5,
        },
      },
    },
  };
}

// Re-set mock implementations before each test (restoreMocks clears factory implementations)
beforeEach(() => {
  // Default: autoInject disabled
  const settings = createSettingsWithAutoInject({ enabled: false });
  mockGetSettings.mockReturnValue(settings);
  mockGetSettings.mockReturnValue(settings);

  (categorizeError as ReturnType<typeof vi.fn>).mockReturnValue({
    code: 'UNKNOWN',
    category: 'unknown',
    message: 'test error',
    retryable: false,
  });
  (ContextLoader as ReturnType<typeof vi.fn>).mockImplementation(() => ({
    load: vi.fn().mockResolvedValue({ files: [], merged: '' }),
  }));
  (detectProviderFromModel as ReturnType<typeof vi.fn>).mockReturnValue('anthropic');
  (createRulesTracker as ReturnType<typeof vi.fn>).mockReturnValue({
    setRules: vi.fn(),
    getRules: vi.fn().mockReturnValue([]),
    getRulesContent: vi.fn().mockReturnValue(''),
  });
  (createSkillTracker as ReturnType<typeof vi.fn>).mockReturnValue({
    getSkills: vi.fn().mockReturnValue([]),
  });
  (createSubAgentTracker as ReturnType<typeof vi.fn>).mockReturnValue({
    getResults: vi.fn().mockReturnValue([]),
  });
  (createTodoTracker as ReturnType<typeof vi.fn>).mockReturnValue({
    getTodos: vi.fn().mockReturnValue([]),
  });
  (createTrackerReconstructor as ReturnType<typeof vi.fn>).mockReturnValue({
    reconstruct: vi.fn().mockReturnValue({
      skillTracker: { count: 0, getSkills: vi.fn().mockReturnValue([]) },
      rulesTracker: {
        hasRules: vi.fn().mockReturnValue(false),
        getTotalFiles: vi.fn().mockReturnValue(0),
        getRulesFiles: vi.fn().mockReturnValue([]),
        getRulesContent: vi.fn().mockReturnValue(''),
      },
      subagentTracker: { count: 0, activeCount: 0, getResults: vi.fn().mockReturnValue([]) },
      todoTracker: { count: 0, hasIncompleteTasks: false, getTodos: vi.fn().mockReturnValue([]) },
      apiTokenCount: undefined,
    }),
  });
  (createSessionContext as ReturnType<typeof vi.fn>).mockReturnValue({
    getHeadEventId: vi.fn().mockReturnValue('head-1'),
    appendEvent: vi.fn().mockResolvedValue({ id: 'mem-evt-1' }),
    restoreFromEvents: vi.fn(),
    setMessagesWithEventIds: vi.fn(),
    isProcessing: vi.fn().mockReturnValue(false),
  });
  (buildWorktreeInfo as ReturnType<typeof vi.fn>).mockReturnValue({});
});

// =============================================================================
// Helpers
// =============================================================================

function createMockAgent() {
  return {
    setRulesContent: vi.fn(),
    setMemoryContent: vi.fn(),
    setReasoningLevel: vi.fn(),
    addMessage: vi.fn(),
    run: vi.fn(),
    stop: vi.fn(),
    getPendingBackgroundHookCount: vi.fn().mockReturnValue(0),
    getContextManager: vi.fn().mockReturnValue({
      setApiContextTokens: vi.fn(),
    }),
  };
}

function createMockEventStore() {
  return {
    createSession: vi.fn().mockResolvedValue({
      session: { id: 'sess-1' },
      rootEvent: { id: 'root-1' },
    }),
    append: vi.fn().mockResolvedValue({ id: 'evt-1' }),
    getSession: vi.fn().mockResolvedValue({
      id: 'sess-1',
      workingDirectory: '/project',
      model: 'claude-sonnet-4-5-20250929',
      latestModel: 'claude-sonnet-4-5-20250929',
      headEventId: 'head-1',
    }),
    getStateAtHead: vi.fn().mockResolvedValue({
      messagesWithEventIds: [],
      reasoningLevel: undefined,
      systemPrompt: undefined,
    }),
    getAncestors: vi.fn().mockResolvedValue([]),
    getEvents: vi.fn().mockReturnValue([]),
    getEventsByType: vi.fn().mockReturnValue([]),
    endSession: vi.fn(),
  };
}

function createMockWorktreeCoordinator() {
  return {
    acquire: vi.fn().mockResolvedValue({
      path: '/project',
      isIsolated: false,
      release: vi.fn(),
    }),
    release: vi.fn(),
  };
}

function createConfig(overrides: Partial<SessionManagerConfig> = {}): SessionManagerConfig {
  const activeSessions = new Map<string, ActiveSession>();

  return {
    eventStore: createMockEventStore() as any,
    worktreeCoordinator: createMockWorktreeCoordinator() as any,
    defaultModel: 'claude-sonnet-4-5-20250929',
    defaultProvider: 'anthropic',
    getActiveSession: (id: string) => activeSessions.get(id),
    setActiveSession: (id: string, session: ActiveSession) => activeSessions.set(id, session),
    deleteActiveSession: (id: string) => activeSessions.delete(id),
    getActiveSessionCount: () => activeSessions.size,
    getAllActiveSessions: () => activeSessions.entries(),
    createAgentForSession: vi.fn().mockResolvedValue(createMockAgent()),
    emit: vi.fn(),
    estimateTokens: vi.fn().mockReturnValue(100),
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('SessionManager - Memory Injection', () => {
  let config: SessionManagerConfig;
  let mockAgent: ReturnType<typeof createMockAgent>;

  beforeEach(() => {
    mockAgent = createMockAgent();
    config = createConfig({
      createAgentForSession: vi.fn().mockResolvedValue(mockAgent),
    });
  });

  describe('createSession - autoInject disabled (default)', () => {
    it('should NOT call loadWorkspaceMemory when autoInject is disabled', async () => {
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue({
        content: '# Memory\n\n## Recent sessions\n\n### Session 1\n- lesson 1',
        count: 1,
        tokens: 20,
      });

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(config.loadWorkspaceMemory).not.toHaveBeenCalled();
      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });

    it('should NOT call loadWorkspaceMemory when no callback is configured', async () => {
      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });
  });

  describe('createSession - autoInject enabled', () => {
    beforeEach(() => {
      const settings = createSettingsWithAutoInject({ enabled: true, count: 5 });
      mockGetSettings.mockReturnValue(settings);
      mockGetSettings.mockReturnValue(settings);
    });

    it('should inject memory content when loadWorkspaceMemory returns content', async () => {
      const memoryResult = {
        content: '# Memory\n\n## Recent sessions\n\n### Session 1\n- Always validate input',
        count: 1,
        tokens: 20,
      };
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue(memoryResult);

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(config.loadWorkspaceMemory).toHaveBeenCalledWith('/project', { count: 5 });
      expect(mockAgent.setMemoryContent).toHaveBeenCalledWith(memoryResult.content);
    });

    it('should emit memory.loaded event when memories are injected', async () => {
      const memoryResult = {
        content: '# Memory\n\n## Recent\n\n### Session 1\n- lesson',
        count: 3,
        tokens: 42,
      };
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue(memoryResult);

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      // memory.loaded is emitted via eventStore.append (not sessionContext.appendEvent)
      // so it broadcasts over WebSocket for pill notifications
      const mockEventStore = config.eventStore as ReturnType<typeof createMockEventStore>;
      const appendCalls = mockEventStore.append.mock.calls;
      const memoryCall = appendCalls.find(
        (call: unknown[]) => (call[0] as Record<string, unknown>).type === 'memory.loaded'
      );
      expect(memoryCall).toBeDefined();
      expect((memoryCall![0] as Record<string, unknown>).payload).toEqual({
        count: 3,
        tokens: 42,
        workspaceId: '',
      });
    });

    it('should pass count from settings to loadWorkspaceMemory', async () => {
      const settings = createSettingsWithAutoInject({ enabled: true, count: 3 });
      mockGetSettings.mockReturnValue(settings);
      mockGetSettings.mockReturnValue(settings);

      config.loadWorkspaceMemory = vi.fn().mockResolvedValue({
        content: '# Memory\n\n### S1\n- lesson',
        count: 3,
        tokens: 10,
      });

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(config.loadWorkspaceMemory).toHaveBeenCalledWith('/project', { count: 3 });
    });

    it('should not inject memory when loadWorkspaceMemory returns undefined', async () => {
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue(undefined);

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(config.loadWorkspaceMemory).toHaveBeenCalledWith('/project', { count: 5 });
      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });

    it('should not emit memory.loaded when loadWorkspaceMemory returns undefined', async () => {
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue(undefined);

      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      const mockEventStore = config.eventStore as ReturnType<typeof createMockEventStore>;
      const appendCalls = mockEventStore.append.mock.calls;
      const memoryCall = appendCalls.find(
        (call: unknown[]) => (call[0] as Record<string, unknown>).type === 'memory.loaded'
      );
      expect(memoryCall).toBeUndefined();
    });

    it('should handle loadWorkspaceMemory failure gracefully', async () => {
      config.loadWorkspaceMemory = vi.fn().mockRejectedValue(new Error('DB error'));

      const manager = new SessionManager(config);
      const result = await manager.createSession({ workingDirectory: '/project' });

      expect(result).toBeDefined();
      expect(result.sessionId).toBe('sess-1');
      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });

    it('should still create session successfully even if memory loading fails', async () => {
      config.loadWorkspaceMemory = vi.fn().mockRejectedValue(new Error('Embedding service down'));

      const manager = new SessionManager(config);
      const result = await manager.createSession({ workingDirectory: '/project' });

      expect(result.sessionId).toBe('sess-1');
      expect(config.emit).toHaveBeenCalled();
    });

    it('should not call loadWorkspaceMemory when callback is not configured', async () => {
      // No loadWorkspaceMemory callback, but autoInject is enabled
      const manager = new SessionManager(config);
      await manager.createSession({ workingDirectory: '/project' });

      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });
  });

  describe('resumeSession - autoInject disabled (default)', () => {
    it('should NOT call loadWorkspaceMemory when autoInject is disabled', async () => {
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue({
        content: '# Memory\n\n### S1\n- lesson',
        count: 1,
        tokens: 10,
      });

      const manager = new SessionManager(config);
      await manager.resumeSession('sess-1');

      expect(config.loadWorkspaceMemory).not.toHaveBeenCalled();
      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });
  });

  describe('resumeSession - autoInject enabled', () => {
    beforeEach(() => {
      const settings = createSettingsWithAutoInject({ enabled: true, count: 5 });
      mockGetSettings.mockReturnValue(settings);
      mockGetSettings.mockReturnValue(settings);
    });

    it('should inject memory content on resume', async () => {
      const memoryResult = {
        content: '# Memory\n\n## Recent\n\n### Session 1\n- lesson',
        count: 1,
        tokens: 15,
      };
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue(memoryResult);

      const manager = new SessionManager(config);
      await manager.resumeSession('sess-1');

      expect(config.loadWorkspaceMemory).toHaveBeenCalledWith('/project', { count: 5 });
      expect(mockAgent.setMemoryContent).toHaveBeenCalledWith(memoryResult.content);
    });

    it('should NOT emit memory.loaded event on resume (original event already in history)', async () => {
      config.loadWorkspaceMemory = vi.fn().mockResolvedValue({
        content: '# Memory\n\n### S1\n- lesson',
        count: 1,
        tokens: 10,
      });

      const manager = new SessionManager(config);
      await manager.resumeSession('sess-1');

      // No memory.loaded via eventStore.append on resume
      const mockEventStore = config.eventStore as ReturnType<typeof createMockEventStore>;
      const appendCalls = mockEventStore.append.mock.calls;
      const memoryCall = appendCalls.find(
        (call: unknown[]) => (call[0] as Record<string, unknown>).type === 'memory.loaded'
      );
      expect(memoryCall).toBeUndefined();
    });

    it('should handle loadWorkspaceMemory failure gracefully on resume', async () => {
      config.loadWorkspaceMemory = vi.fn().mockRejectedValue(new Error('DB error'));

      const manager = new SessionManager(config);
      const result = await manager.resumeSession('sess-1');

      expect(result).toBeDefined();
      expect(mockAgent.setMemoryContent).not.toHaveBeenCalled();
    });
  });
});
