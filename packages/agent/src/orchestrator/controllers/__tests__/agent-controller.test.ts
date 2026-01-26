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
  let mockGetActiveSession: ReturnType<typeof vi.fn>;
  let mockResumeSession: ReturnType<typeof vi.fn>;
  let controller: AgentController;

  const mockActiveSession = {
    sessionId: 'sess-123',
    workingDir: '/test/project',
    lastActivity: new Date(),
    wasInterrupted: false,
    agent: {
      abort: vi.fn(),
    },
    sessionContext: {
      isProcessing: vi.fn(),
      setProcessing: vi.fn(),
    },
    subagentTracker: {},
    skillTracker: {},
  } as unknown as ActiveSession;

  beforeEach(() => {
    vi.clearAllMocks();

    mockAgentRunner = {
      run: vi.fn(),
    };

    mockGetActiveSession = vi.fn();
    mockResumeSession = vi.fn();

    controller = createAgentController({
      agentRunner: mockAgentRunner,
      getActiveSession: mockGetActiveSession,
      resumeSession: mockResumeSession,
    });
  });

  // ===========================================================================
  // run
  // ===========================================================================

  describe('run', () => {
    it('runs agent on active session', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([{ content: 'Hello' }]);

      const result = await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect(mockGetActiveSession).toHaveBeenCalledWith('sess-123');
      expect(mockActiveSession.sessionContext.setProcessing).toHaveBeenCalledWith(true);
      expect(mockAgentRunner.run).toHaveBeenCalledWith(mockActiveSession, {
        sessionId: 'sess-123',
        prompt: 'Hello',
      });
      expect(result).toEqual([{ content: 'Hello' }]);
    });

    it('auto-resumes inactive session', async () => {
      // First call returns undefined (not active), second returns the session
      mockGetActiveSession
        .mockReturnValueOnce(undefined)
        .mockReturnValueOnce(mockActiveSession);
      mockResumeSession.mockResolvedValue({});
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect(mockResumeSession).toHaveBeenCalledWith('sess-123');
      expect(mockAgentRunner.run).toHaveBeenCalled();
    });

    it('throws error if session not found after resume attempt', async () => {
      mockGetActiveSession.mockReturnValue(undefined);
      mockResumeSession.mockRejectedValue(new Error('Not found'));

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Session not found: sess-123');
    });

    it('throws error if resume succeeds but session still not active', async () => {
      mockGetActiveSession.mockReturnValue(undefined);
      mockResumeSession.mockResolvedValue({});

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Failed to resume session: sess-123');
    });

    it('throws error if session already processing', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(true);

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Session is already processing');
    });

    it('clears processing state on success', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      // setProcessing should be called with true at start, then false at end
      expect(mockActiveSession.sessionContext.setProcessing).toHaveBeenNthCalledWith(1, true);
      expect(mockActiveSession.sessionContext.setProcessing).toHaveBeenNthCalledWith(2, false);
    });

    it('clears processing state on error', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockRejectedValue(new Error('Agent failed'));

      await expect(controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      })).rejects.toThrow('Agent failed');

      // Processing should be cleared even on error
      expect(mockActiveSession.sessionContext.setProcessing).toHaveBeenLastCalledWith(false);
    });

    it('updates lastActivity timestamp', async () => {
      const originalDate = mockActiveSession.lastActivity;
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);
      mockAgentRunner.run.mockResolvedValue([]);

      await controller.run({
        sessionId: 'sess-123',
        prompt: 'Hello',
      });

      expect(mockActiveSession.lastActivity).not.toBe(originalDate);
    });
  });

  // ===========================================================================
  // cancel
  // ===========================================================================

  describe('cancel', () => {
    it('returns false when session not found', async () => {
      mockGetActiveSession.mockReturnValue(undefined);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(false);
    });

    it('returns false when session not processing', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(false);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(false);
      expect(mockActiveSession.agent.abort).not.toHaveBeenCalled();
    });

    it('aborts agent and returns true when processing', async () => {
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(true);

      const result = await controller.cancel('sess-123');

      expect(result).toBe(true);
      expect(mockActiveSession.agent.abort).toHaveBeenCalled();
      expect(mockActiveSession.sessionContext.setProcessing).toHaveBeenCalledWith(false);
    });

    it('updates lastActivity timestamp on cancel', async () => {
      const originalDate = mockActiveSession.lastActivity;
      mockGetActiveSession.mockReturnValue(mockActiveSession);
      mockActiveSession.sessionContext.isProcessing.mockReturnValue(true);

      await controller.cancel('sess-123');

      expect(mockActiveSession.lastActivity).not.toBe(originalDate);
    });
  });

  // ===========================================================================
  // Factory Function
  // ===========================================================================

  describe('createAgentController', () => {
    it('creates an AgentController instance', () => {
      const ctrl = createAgentController({
        agentRunner: mockAgentRunner,
        getActiveSession: mockGetActiveSession,
        resumeSession: mockResumeSession,
      });

      expect(ctrl).toBeInstanceOf(AgentController);
    });
  });
});
