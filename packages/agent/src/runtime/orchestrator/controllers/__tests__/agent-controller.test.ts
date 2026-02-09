/**
 * @fileoverview AgentController Tests
 *
 * Tests for the AgentController which manages agent execution.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  AgentController,
  createAgentController,
  type AgentControllerConfig,
} from '../agent-controller.js';
import type { ActiveSession } from '../../types.js';

describe('AgentController', () => {
  let mockAgentRunner: any;
  let mockSessionStore: {
    get: ReturnType<typeof vi.fn>;
    set: ReturnType<typeof vi.fn>;
    delete: ReturnType<typeof vi.fn>;
    clear: ReturnType<typeof vi.fn>;
    size: number;
    entries: ReturnType<typeof vi.fn>;
    values: ReturnType<typeof vi.fn>;
  };
  let mockResumeSession: ReturnType<typeof vi.fn>;
  let controller: AgentController;

  const mockActiveSession = {
    sessionId: 'sess-123',
    workingDir: '/test/project',
    wasInterrupted: false,
    agent: {
      abort: vi.fn(),
      getPendingBackgroundHookCount: vi.fn().mockReturnValue(0),
      waitForBackgroundHooks: vi.fn().mockResolvedValue(undefined),
    },
    sessionContext: {
      isProcessing: vi.fn(),
      setProcessing: vi.fn(),
      touch: vi.fn(),
    },
    subagentTracker: {},
    skillTracker: {},
  } as any as ActiveSession;

  beforeEach(() => {
    vi.clearAllMocks();

    mockAgentRunner = {
      run: vi.fn(),
    };

    mockSessionStore = {
      get: vi.fn(),
      set: vi.fn(),
      delete: vi.fn(),
      clear: vi.fn(),
      get size() { return 0; },
      entries: vi.fn().mockReturnValue([][Symbol.iterator]()),
      values: vi.fn().mockReturnValue([][Symbol.iterator]()),
    };
    mockResumeSession = vi.fn();

    controller = createAgentController({
      agentRunner: mockAgentRunner,
      sessionStore: mockSessionStore,
      resumeSession: mockResumeSession,
    });
  });

  // ===========================================================================
  // run
  // ===========================================================================

  describe('run', () => {
    it('runs agent on active session', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([{ content: 'Hello' }]);

      const result = await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect(mockSessionStore.get).toHaveBeenCalledWith('sess-123');
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenCalledWith(true);
      expect(mockAgentRunner.run).toHaveBeenCalledWith(mockActiveSession, {
        sessionId: 'sess-123',
        prompt: 'Hello',
      });
      expect(result).toEqual([{ content: 'Hello' }]);
    });

    it('auto-resumes inactive session', async () => {
      // First call returns undefined (not active), second returns the session
      mockSessionStore.get
        .mockReturnValueOnce(undefined)
        .mockReturnValueOnce(mockActiveSession);
      mockResumeSession.mockResolvedValue({});
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect(mockResumeSession).toHaveBeenCalledWith('sess-123');
      expect(mockAgentRunner.run).toHaveBeenCalled();
    });

    it('throws error if session not found after resume attempt', async () => {
      mockSessionStore.get.mockReturnValue(undefined);
      mockResumeSession.mockRejectedValue(new Error('Not found'));

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Session not found: sess-123');
    });

    it('throws error if resume succeeds but session still not active', async () => {
      mockSessionStore.get.mockReturnValue(undefined);
      mockResumeSession.mockResolvedValue({});

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Failed to resume session: sess-123');
    });

    it('throws error if session already processing', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(true);

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Session is already processing');
    });

    it('clears processing state on success', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      // setProcessing should be called with true at start, then false at end
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenNthCalledWith(1, true);
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenNthCalledWith(2, false);
    });

    it('clears processing state on error', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockRejectedValue(new Error('Agent failed'));

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Agent failed');

      // Processing should be cleared even on error
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenLastCalledWith(false);
    });

    it('waits for pending background hooks before starting new run', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      (mockActiveSession.agent as any).getPendingBackgroundHookCount.mockReturnValue(2);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect((mockActiveSession.agent as any).waitForBackgroundHooks).toHaveBeenCalledWith(10_000);
      expect(mockAgentRunner.run).toHaveBeenCalled();
    });

    it('skips background hook wait when none are pending', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      (mockActiveSession.agent as any).getPendingBackgroundHookCount.mockReturnValue(0);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect((mockActiveSession.agent as any).waitForBackgroundHooks).not.toHaveBeenCalled();
    });

    it('updates activity timestamp via sessionContext.setProcessing', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      // setProcessing(true) internally calls touch() on SessionContext
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenCalledWith(true);
    });
  });

  // ===========================================================================
  // cancel
  // ===========================================================================

  describe('cancel', () => {
    it('returns false when session not found', async () => {
      mockSessionStore.get.mockReturnValue(undefined);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(false);
    });

    it('returns false when session not processing', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(false);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(false);
      expect(mockActiveSession.agent.abort).not.toHaveBeenCalled();
    });

    it('aborts agent and returns true when processing', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(true);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(true);
      expect(mockActiveSession.agent.abort).toHaveBeenCalled();
      expect((mockActiveSession.sessionContext as any).setProcessing).toHaveBeenCalledWith(false);
    });

    it('touches session context on cancel', async () => {
      mockSessionStore.get.mockReturnValue(mockActiveSession);
      (mockActiveSession.sessionContext as any).isProcessing.mockReturnValue(true);

      await controller.cancel('sess-123');

      expect((mockActiveSession.sessionContext as any).touch).toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Factory Function
  // ===========================================================================

  describe('createAgentController', () => {
    it('creates an AgentController instance', () => {
      const ctrl = createAgentController({
        agentRunner: mockAgentRunner,
        sessionStore: mockSessionStore,
        resumeSession: mockResumeSession,
      });

      expect(ctrl).toBeInstanceOf(AgentController);
    });
  });
});
