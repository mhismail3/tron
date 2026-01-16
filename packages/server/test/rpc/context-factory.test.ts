/**
 * @fileoverview Tests for RPC Context Factory
 *
 * Tests the composition of all adapters into a complete RpcContext.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createRpcContext,
  createMinimalRpcContext,
  isFullRpcContext,
} from '../../src/rpc/context-factory.js';
import type { EventStoreOrchestrator } from '../../src/event-store-orchestrator.js';

// Mock all adapter modules
vi.mock('../../src/rpc/adapters/session.adapter.js', () => ({
  createSessionAdapter: vi.fn().mockReturnValue({
    createSession: vi.fn(),
    getSession: vi.fn(),
    resumeSession: vi.fn(),
    listSessions: vi.fn(),
    deleteSession: vi.fn(),
    forkSession: vi.fn(),
    switchModel: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/agent.adapter.js', () => ({
  createAgentAdapter: vi.fn().mockReturnValue({
    prompt: vi.fn(),
    abort: vi.fn(),
    getState: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/memory.adapter.js', () => ({
  createMemoryAdapter: vi.fn().mockReturnValue({
    searchEntries: vi.fn(),
    addEntry: vi.fn(),
    listHandoffs: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/transcription.adapter.js', () => ({
  createTranscriptionAdapter: vi.fn().mockReturnValue({
    transcribeAudio: vi.fn(),
    listModels: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/event-store.adapter.js', () => ({
  createEventStoreAdapter: vi.fn().mockReturnValue({
    getEventHistory: vi.fn(),
    getEventsSince: vi.fn(),
    appendEvent: vi.fn(),
    getTreeVisualization: vi.fn(),
    getBranches: vi.fn(),
    getSubtree: vi.fn(),
    getAncestors: vi.fn(),
    searchContent: vi.fn(),
    deleteMessage: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/worktree.adapter.js', () => ({
  createWorktreeAdapter: vi.fn().mockReturnValue({
    getWorktreeStatus: vi.fn(),
    commitWorktree: vi.fn(),
    mergeWorktree: vi.fn(),
    listWorktrees: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/context.adapter.js', () => ({
  createContextAdapter: vi.fn().mockReturnValue({
    getContextSnapshot: vi.fn(),
    getDetailedContextSnapshot: vi.fn(),
    shouldCompact: vi.fn(),
    previewCompaction: vi.fn(),
    confirmCompaction: vi.fn(),
    canAcceptTurn: vi.fn(),
    clearContext: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/browser.adapter.js', () => ({
  createBrowserAdapter: vi.fn().mockReturnValue({
    startStream: vi.fn(),
    stopStream: vi.fn(),
    getStatus: vi.fn(),
  }),
}));

vi.mock('../../src/rpc/adapters/skill.adapter.js', () => ({
  createSkillAdapter: vi.fn().mockReturnValue({
    listSkills: vi.fn(),
    getSkill: vi.fn(),
    refreshSkills: vi.fn(),
    removeSkill: vi.fn(),
  }),
}));

// Import mocked functions to verify calls
import { createSessionAdapter } from '../../src/rpc/adapters/session.adapter.js';
import { createAgentAdapter } from '../../src/rpc/adapters/agent.adapter.js';
import { createMemoryAdapter } from '../../src/rpc/adapters/memory.adapter.js';
import { createTranscriptionAdapter } from '../../src/rpc/adapters/transcription.adapter.js';
import { createEventStoreAdapter } from '../../src/rpc/adapters/event-store.adapter.js';
import { createWorktreeAdapter } from '../../src/rpc/adapters/worktree.adapter.js';
import { createContextAdapter } from '../../src/rpc/adapters/context.adapter.js';
import { createBrowserAdapter } from '../../src/rpc/adapters/browser.adapter.js';
import { createSkillAdapter } from '../../src/rpc/adapters/skill.adapter.js';

describe('RpcContextFactory', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  beforeEach(() => {
    vi.clearAllMocks();

    mockOrchestrator = {
      createSession: vi.fn(),
      getSession: vi.fn(),
      listSessions: vi.fn(),
      runAgent: vi.fn(),
      cancelAgent: vi.fn(),
      getActiveSession: vi.fn(),
    };
  });

  describe('createRpcContext', () => {
    it('should create context with all required managers', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Required managers must exist
      expect(context.sessionManager).toBeDefined();
      expect(context.agentManager).toBeDefined();
      expect(context.memoryStore).toBeDefined();
    });

    it('should create context with all optional managers by default', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Optional managers should exist
      expect(context.eventStore).toBeDefined();
      expect(context.worktreeManager).toBeDefined();
      expect(context.contextManager).toBeDefined();
      expect(context.browserManager).toBeDefined();
      expect(context.skillManager).toBeDefined();
      expect(context.transcriptionManager).toBeDefined();
    });

    it('should call adapter factories with correct dependencies', () => {
      const deps = { orchestrator: mockOrchestrator as EventStoreOrchestrator };

      createRpcContext(deps);

      // Orchestrator-dependent adapters should receive deps
      expect(createSessionAdapter).toHaveBeenCalledWith(deps);
      expect(createAgentAdapter).toHaveBeenCalledWith(deps);
      expect(createEventStoreAdapter).toHaveBeenCalledWith(deps);
      expect(createWorktreeAdapter).toHaveBeenCalledWith(deps);
      expect(createContextAdapter).toHaveBeenCalledWith(deps);
      expect(createBrowserAdapter).toHaveBeenCalledWith(deps);
      expect(createSkillAdapter).toHaveBeenCalledWith(deps);

      // Standalone adapters should be called without deps
      expect(createMemoryAdapter).toHaveBeenCalledWith();
      expect(createTranscriptionAdapter).toHaveBeenCalledWith();
    });

    it('should skip optional managers in minimal mode', () => {
      const context = createRpcContext(
        { orchestrator: mockOrchestrator as EventStoreOrchestrator },
        { minimal: true },
      );

      // Required managers must exist
      expect(context.sessionManager).toBeDefined();
      expect(context.agentManager).toBeDefined();
      expect(context.memoryStore).toBeDefined();

      // Optional managers should be undefined
      expect(context.eventStore).toBeUndefined();
      expect(context.worktreeManager).toBeUndefined();
      expect(context.contextManager).toBeUndefined();
      expect(context.browserManager).toBeUndefined();
      expect(context.skillManager).toBeUndefined();
      expect(context.transcriptionManager).toBeUndefined();
    });

    it('should not call optional adapter factories in minimal mode', () => {
      vi.clearAllMocks();

      createRpcContext(
        { orchestrator: mockOrchestrator as EventStoreOrchestrator },
        { minimal: true },
      );

      // Required adapters should be called
      expect(createSessionAdapter).toHaveBeenCalled();
      expect(createAgentAdapter).toHaveBeenCalled();
      expect(createMemoryAdapter).toHaveBeenCalled();

      // Optional adapters should NOT be called
      expect(createEventStoreAdapter).not.toHaveBeenCalled();
      expect(createWorktreeAdapter).not.toHaveBeenCalled();
      expect(createContextAdapter).not.toHaveBeenCalled();
      expect(createBrowserAdapter).not.toHaveBeenCalled();
      expect(createSkillAdapter).not.toHaveBeenCalled();
      expect(createTranscriptionAdapter).not.toHaveBeenCalled();
    });

    it('should skip transcription when skipTranscription option is set', () => {
      vi.clearAllMocks();

      const context = createRpcContext(
        { orchestrator: mockOrchestrator as EventStoreOrchestrator },
        { skipTranscription: true },
      );

      expect(context.transcriptionManager).toBeUndefined();
      expect(createTranscriptionAdapter).not.toHaveBeenCalled();

      // Other optional managers should still exist
      expect(context.eventStore).toBeDefined();
      expect(context.worktreeManager).toBeDefined();
    });

    it('should return context with proper types', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify required manager methods exist (type safety)
      expect(typeof context.sessionManager.createSession).toBe('function');
      expect(typeof context.sessionManager.getSession).toBe('function');
      expect(typeof context.agentManager.prompt).toBe('function');
      expect(typeof context.agentManager.abort).toBe('function');
      expect(typeof context.memoryStore.searchEntries).toBe('function');
    });
  });

  describe('createMinimalRpcContext', () => {
    it('should create context with only required managers', () => {
      const context = createMinimalRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Required managers must exist
      expect(context.sessionManager).toBeDefined();
      expect(context.agentManager).toBeDefined();
      expect(context.memoryStore).toBeDefined();

      // Optional managers should be undefined
      expect(context.eventStore).toBeUndefined();
      expect(context.worktreeManager).toBeUndefined();
      expect(context.contextManager).toBeUndefined();
      expect(context.browserManager).toBeUndefined();
      expect(context.skillManager).toBeUndefined();
      expect(context.transcriptionManager).toBeUndefined();
    });

    it('should be equivalent to createRpcContext with minimal: true', () => {
      vi.clearAllMocks();

      const minimalContext = createMinimalRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      vi.clearAllMocks();

      const explicitMinimalContext = createRpcContext(
        { orchestrator: mockOrchestrator as EventStoreOrchestrator },
        { minimal: true },
      );

      // Both should have same shape
      expect(Object.keys(minimalContext).sort()).toEqual(
        Object.keys(explicitMinimalContext).sort(),
      );
    });
  });

  describe('isFullRpcContext', () => {
    it('should return true for full context', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      expect(isFullRpcContext(context)).toBe(true);
    });

    it('should return false for minimal context', () => {
      const context = createMinimalRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      expect(isFullRpcContext(context)).toBe(false);
    });

    it('should return false when any optional manager is missing', () => {
      const context = createRpcContext(
        { orchestrator: mockOrchestrator as EventStoreOrchestrator },
        { skipTranscription: true },
      );

      expect(isFullRpcContext(context)).toBe(false);
    });
  });

  describe('adapter composition', () => {
    it('should compose session manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify sessionManager has all expected methods
      expect(context.sessionManager).toHaveProperty('createSession');
      expect(context.sessionManager).toHaveProperty('getSession');
      expect(context.sessionManager).toHaveProperty('resumeSession');
      expect(context.sessionManager).toHaveProperty('listSessions');
      expect(context.sessionManager).toHaveProperty('deleteSession');
      expect(context.sessionManager).toHaveProperty('forkSession');
      expect(context.sessionManager).toHaveProperty('switchModel');
    });

    it('should compose agent manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify agentManager has all expected methods
      expect(context.agentManager).toHaveProperty('prompt');
      expect(context.agentManager).toHaveProperty('abort');
      expect(context.agentManager).toHaveProperty('getState');
    });

    it('should compose event store manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify eventStore has all expected methods
      expect(context.eventStore).toHaveProperty('getEventHistory');
      expect(context.eventStore).toHaveProperty('getEventsSince');
      expect(context.eventStore).toHaveProperty('appendEvent');
      expect(context.eventStore).toHaveProperty('getTreeVisualization');
      expect(context.eventStore).toHaveProperty('getBranches');
      expect(context.eventStore).toHaveProperty('getSubtree');
      expect(context.eventStore).toHaveProperty('getAncestors');
      expect(context.eventStore).toHaveProperty('searchContent');
      expect(context.eventStore).toHaveProperty('deleteMessage');
    });

    it('should compose worktree manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify worktreeManager has all expected methods
      expect(context.worktreeManager).toHaveProperty('getWorktreeStatus');
      expect(context.worktreeManager).toHaveProperty('commitWorktree');
      expect(context.worktreeManager).toHaveProperty('mergeWorktree');
      expect(context.worktreeManager).toHaveProperty('listWorktrees');
    });

    it('should compose context manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify contextManager has all expected methods
      expect(context.contextManager).toHaveProperty('getContextSnapshot');
      expect(context.contextManager).toHaveProperty('getDetailedContextSnapshot');
      expect(context.contextManager).toHaveProperty('shouldCompact');
      expect(context.contextManager).toHaveProperty('previewCompaction');
      expect(context.contextManager).toHaveProperty('confirmCompaction');
      expect(context.contextManager).toHaveProperty('canAcceptTurn');
      expect(context.contextManager).toHaveProperty('clearContext');
    });

    it('should compose browser manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify browserManager has all expected methods
      expect(context.browserManager).toHaveProperty('startStream');
      expect(context.browserManager).toHaveProperty('stopStream');
      expect(context.browserManager).toHaveProperty('getStatus');
    });

    it('should compose skill manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify skillManager has all expected methods
      expect(context.skillManager).toHaveProperty('listSkills');
      expect(context.skillManager).toHaveProperty('getSkill');
      expect(context.skillManager).toHaveProperty('refreshSkills');
      expect(context.skillManager).toHaveProperty('removeSkill');
    });

    it('should compose transcription manager with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify transcriptionManager has all expected methods
      expect(context.transcriptionManager).toHaveProperty('transcribeAudio');
      expect(context.transcriptionManager).toHaveProperty('listModels');
    });

    it('should compose memory store with correct interface', () => {
      const context = createRpcContext({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      // Verify memoryStore has all expected methods (deprecated but present)
      expect(context.memoryStore).toHaveProperty('searchEntries');
      expect(context.memoryStore).toHaveProperty('addEntry');
      expect(context.memoryStore).toHaveProperty('listHandoffs');
    });
  });
});
