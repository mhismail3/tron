/**
 * @fileoverview Tests for Agent Adapter
 *
 * The agent adapter handles agent prompts, abort, and state retrieval.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createAgentAdapter } from '../agent.adapter.js';
import type { EventStoreOrchestrator } from '../../../../orchestrator/persistence/event-store-orchestrator.js';

// Use vi.hoisted to define mocks before they're hoisted
const { mockLogger } = vi.hoisted(() => ({
  mockLogger: {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
    trace: vi.fn(),
  },
}));

// Mock the SkillRegistry
vi.mock('../../../../skills/index.js', () => ({
  SkillRegistry: vi.fn().mockImplementation(() => ({
    initialize: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockReturnValue([]),
    get: vi.fn().mockReturnValue(null),
  })),
}));

// Mock the logging module
vi.mock('../../../../logging/index.js', () => ({
  createLogger: vi.fn(() => mockLogger),
  categorizeError: vi.fn((err: Error, ctx?: Record<string, unknown>) => ({
    code: 'TEST_ERROR',
    message: err.message,
    category: 'SESSION_STATE',
    retryable: false,
    context: ctx,
  })),
  LogErrorCategory: {
    SESSION_STATE: 'SESSION_STATE',
    FILESYSTEM: 'FILESYSTEM',
  },
}));

describe('AgentAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;
  let mockAgent: any;
  let mockSessionContext: any;

  beforeEach(() => {
    vi.clearAllMocks();
    mockLogger.info.mockClear();
    mockLogger.warn.mockClear();
    mockLogger.error.mockClear();
    mockLogger.debug.mockClear();
    mockLogger.trace.mockClear();

    mockAgent = {
      getState: vi.fn().mockReturnValue({
        currentTurn: 2,
        messages: [{ role: 'user' }, { role: 'assistant' }],
        tokenUsage: {
          inputTokens: 100,
          outputTokens: 50,
        },
      }),
    };

    mockSessionContext = {
      isProcessing: vi.fn().mockReturnValue(false),
      getAccumulatedContent: vi.fn().mockReturnValue({
        text: 'partial response',
        toolCalls: [],
      }),
    };

    mockOrchestrator = {
      agent: {
        run: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn(),
      },
      sessions: {
        getSession: vi.fn(),
        wasSessionInterrupted: vi.fn(),
      },
      getActiveSession: vi.fn(),
    } as any;
  });

  describe('prompt', () => {
    it('should start agent run and return acknowledged', async () => {
      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.prompt({
        sessionId: 'sess-123',
        prompt: 'Hello, world!',
      });

      expect(result).toEqual({ acknowledged: true });
      expect(mockOrchestrator.agent!.run).toHaveBeenCalledWith(
        expect.objectContaining({
          sessionId: 'sess-123',
          prompt: 'Hello, world!',
          skillLoader: expect.any(Function),
        }),
      );
    });

    it('should pass skills and skill loader to agent', async () => {
      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      await adapter.prompt({
        sessionId: 'sess-123',
        prompt: 'Test prompt',
        skills: [{ name: 'test-skill', source: 'project' }],
        reasoningLevel: 'high',
      });

      expect(mockOrchestrator.agent!.run).toHaveBeenCalledWith(
        expect.objectContaining({
          sessionId: 'sess-123',
          prompt: 'Test prompt',
          skills: [{ name: 'test-skill', source: 'project' }],
          reasoningLevel: 'high',
          skillLoader: expect.any(Function),
        }),
      );
    });

    it('should handle agent run errors gracefully', async () => {
      vi.mocked(mockOrchestrator.agent!.run).mockRejectedValue(new Error('Agent error'));

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.prompt({
        sessionId: 'sess-123',
        prompt: 'Test',
      });

      // Should still return acknowledged
      expect(result).toEqual({ acknowledged: true });

      // Wait for the rejected promise to be handled
      await new Promise(resolve => setTimeout(resolve, 10));

      // Verify structured error was logged
      expect(mockLogger.error).toHaveBeenCalledWith(
        'Agent run error',
        expect.objectContaining({
          sessionId: 'sess-123',
          code: 'TEST_ERROR',
          error: 'Agent error',
        }),
      );
    });
  });

  describe('abort', () => {
    it('should cancel agent and return aborted true', async () => {
      vi.mocked(mockOrchestrator.agent!.cancel).mockResolvedValue(true);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.abort('sess-123');

      expect(mockOrchestrator.agent!.cancel).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual({ aborted: true });
    });

    it('should return aborted false when cancel fails', async () => {
      vi.mocked(mockOrchestrator.agent!.cancel).mockResolvedValue(false);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.abort('sess-123');

      expect(result).toEqual({ aborted: false });
    });
  });

  describe('getState', () => {
    it('should return running state when agent is active', async () => {
      mockSessionContext.isProcessing.mockReturnValue(true);
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue({
        wasInterrupted: false,
        agent: mockAgent,
        sessionContext: mockSessionContext,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue({
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.wasSessionInterrupted).mockResolvedValue(false);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.isRunning).toBe(true);
      expect(result.currentTurn).toBe(2);
      expect(result.messageCount).toBe(2); // From agent state
      expect(result.model).toBe('claude-sonnet-4-20250514');
      expect(result.currentTurnText).toBe('partial response');
      expect(result.wasInterrupted).toBe(false);
    });

    it('should return idle state when no active session', async () => {
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue(undefined);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue({
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.wasSessionInterrupted).mockResolvedValue(false);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.isRunning).toBe(false);
      expect(result.currentTurn).toBe(0);
      expect(result.messageCount).toBe(5); // From session
      expect(result.currentTurnText).toBeUndefined();
      expect(result.wasInterrupted).toBe(false);
    });

    it('should detect interrupted session from active flag', async () => {
      mockSessionContext.isProcessing.mockReturnValue(false);
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue({
        wasInterrupted: true,
        agent: mockAgent,
        sessionContext: mockSessionContext,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue({
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
      } as any);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.wasInterrupted).toBe(true);
    });

    it('should detect interrupted session from persisted events', async () => {
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue(undefined);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue({
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.wasSessionInterrupted).mockResolvedValue(true);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.wasInterrupted).toBe(true);
      expect((mockOrchestrator as any).sessions.wasSessionInterrupted).toHaveBeenCalledWith('sess-123');
    });

    it('should return unknown model when session not found', async () => {
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue(undefined);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue(null);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.model).toBe('unknown');
      expect(result.messageCount).toBe(0);
    });

    it('should include token usage from agent state', async () => {
      mockSessionContext.isProcessing.mockReturnValue(true);
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue({
        wasInterrupted: false,
        agent: mockAgent,
        sessionContext: mockSessionContext,
      } as any);
      vi.mocked((mockOrchestrator as any).sessions.getSession).mockResolvedValue({
        model: 'claude-sonnet-4-20250514',
      } as any);

      const adapter = createAgentAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getState('sess-123');

      expect(result.tokenUsage).toEqual({
        input: 100,
        output: 50,
      });
    });
  });
});
