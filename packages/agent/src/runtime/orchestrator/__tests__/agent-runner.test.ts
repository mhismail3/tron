/**
 * @fileoverview AgentRunner Unit Tests (TDD)
 *
 * Tests for the AgentRunner class extracted from EventStoreOrchestrator.
 *
 * Contract:
 * 1. Pre-execution: Flush events, inject skill/subagent/todo contexts
 * 2. User message: Build content from prompt/attachments, record message.user event
 * 3. Reasoning level: Handle reasoning level changes with config.reasoning_level event
 * 4. Execution: Transform content, run agent
 * 5. Interrupt handling: Persist partial content, emit events, mark wasInterrupted
 * 6. Completion: Flush events, emit turn_complete and agent.complete
 * 7. Error handling: Persist error.agent event, emit error events, re-throw
 */
import { describe, it, expect, beforeEach, vi, type Mock } from 'vitest';
import { AgentRunner, createAgentRunner, type AgentRunnerConfig } from '../agent-runner.js';
import type { ActiveSession, AgentRunOptions } from '../types.js';
import type { RunResult } from '../../agent/types.js';

// =============================================================================
// Test Fixtures
// =============================================================================

/**
 * Create a mock ActiveSession for testing.
 */
function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  const mockAgent = {
    run: vi.fn().mockResolvedValue({
      success: true,
      turns: 1,
      stoppedReason: 'end_turn',
      messages: [],
      totalTokenUsage: { inputTokens: 100, outputTokens: 50 },
    } as RunResult),
  };

  const mockSessionContext = {
    flushEvents: vi.fn().mockResolvedValue(undefined),
    appendEvent: vi.fn().mockResolvedValue({ id: 'evt_mock' }),
    addMessageEventId: vi.fn(),
    touch: vi.fn(),
    getReasoningLevel: vi.fn().mockReturnValue(undefined),
    setReasoningLevel: vi.fn(),
    getModel: vi.fn().mockReturnValue('claude-sonnet-4-20250514'),
    getAccumulatedContent: vi.fn().mockReturnValue({ text: '', toolCalls: [] }),
    hasAccumulatedContent: vi.fn().mockReturnValue(false),
    buildInterruptedContent: vi.fn().mockReturnValue({ assistantContent: [], toolResultContent: [] }),
    buildCurrentTurnInterruptedContent: vi.fn().mockReturnValue({ assistantContent: [], toolResultContent: [] }),
    onAgentEnd: vi.fn(),
  };

  const mockSkillTracker = {
    hasSkill: vi.fn().mockReturnValue(false),
    addSkill: vi.fn(),
    removeSkill: vi.fn(),
    getAddedSkills: vi.fn().mockReturnValue([]),
    clear: vi.fn(),
  };

  const mockTodoTracker = {
    buildContextString: vi.fn().mockReturnValue(undefined),
    count: 0,
    buildSummaryString: vi.fn().mockReturnValue(''),
  };

  return {
    sessionId: 'sess_test123',
    agent: mockAgent as any,
    sessionContext: mockSessionContext as any,
    skillTracker: mockSkillTracker as any,
    todoTracker: mockTodoTracker as any,
    workingDirectory: '/test/project',
    model: 'claude-sonnet-4-20250514',
    currentTurn: 0,
    wasInterrupted: false,
    ...overrides,
  } as unknown as ActiveSession;
}

/**
 * Create a mock AgentRunnerConfig for testing.
 */
function createMockConfig(overrides: Partial<AgentRunnerConfig> = {}): AgentRunnerConfig {
  const mockSkillLoader = {
    loadSkillContextForPrompt: vi.fn().mockResolvedValue(undefined),
    transformContentForLLM: vi.fn().mockImplementation((content) => content),
  };

  return {
    skillLoader: mockSkillLoader as any,
    emit: vi.fn(),
    buildSubagentResultsContext: vi.fn().mockReturnValue(undefined),
    ...overrides,
  };
}

/**
 * Create default run options for testing.
 */
function createRunOptions(overrides: Partial<AgentRunOptions> = {}): AgentRunOptions {
  return {
    sessionId: 'sess_test123',
    prompt: 'Hello, world!',
    ...overrides,
  };
}

// =============================================================================
// Unit Tests: Factory Function
// =============================================================================

describe('createAgentRunner', () => {
  it('creates an AgentRunner instance', () => {
    const config = createMockConfig();
    const runner = createAgentRunner(config);

    expect(runner).toBeInstanceOf(AgentRunner);
  });
});

// =============================================================================
// Unit Tests: AgentRunner.run()
// =============================================================================

describe('AgentRunner', () => {
  let runner: AgentRunner;
  let config: AgentRunnerConfig;
  let active: ActiveSession;

  beforeEach(() => {
    config = createMockConfig();
    runner = new AgentRunner(config);
    active = createMockActiveSession();
  });

  describe('run() - Basic Flow', () => {
    it('executes a successful agent run', async () => {
      const options = createRunOptions();

      const results = await runner.run(active, options);

      expect(results).toHaveLength(1);
      expect(results[0].success).toBe(true);
    });

    it('flushes pending events before execution', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.flushEvents).toHaveBeenCalled();
    });

    it('records message.user event', async () => {
      const options = createRunOptions({ prompt: 'Test prompt' });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({ content: 'Test prompt' })
      );
    });

    it('tracks message event ID after recording', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.addMessageEventId).toHaveBeenCalledWith('evt_mock');
    });

    it('runs the agent with transformed content', async () => {
      const options = createRunOptions({ prompt: 'Hello' });

      await runner.run(active, options);

      expect(config.skillLoader.transformContentForLLM).toHaveBeenCalledWith('Hello');
      expect(active.agent.run).toHaveBeenCalled();
    });

    it('touches session context to update activity timestamp', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.touch).toHaveBeenCalled();
    });

    it('touches session context after agent run', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.touch).toHaveBeenCalled();
    });
  });

  describe('run() - Context Injection via RunContext', () => {
    it('loads skill context via skillLoader', async () => {
      const options = createRunOptions({
        skills: [{ name: 'test-skill', source: 'global' }],
      });

      await runner.run(active, options);

      expect(config.skillLoader.loadSkillContextForPrompt).toHaveBeenCalledWith(
        expect.objectContaining({
          sessionId: active.sessionId,
          skillTracker: active.skillTracker,
          sessionContext: active.sessionContext,
        }),
        options
      );
    });

    it('passes skill context to agent.run via RunContext', async () => {
      (config.skillLoader.loadSkillContextForPrompt as Mock).mockResolvedValue(
        '<skills><skill>Test skill content</skill></skills>'
      );
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          skillContext: '<skills><skill>Test skill content</skill></skills>',
        })
      );
    });

    it('passes undefined skillContext when none available', async () => {
      (config.skillLoader.loadSkillContextForPrompt as Mock).mockResolvedValue(undefined);
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          skillContext: undefined,
        })
      );
    });

    it('passes subagent results via RunContext', async () => {
      (config.buildSubagentResultsContext as Mock).mockReturnValue('Subagent completed: result');
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          subagentResults: 'Subagent completed: result',
        })
      );
    });

    it('passes undefined subagentResults when not available', async () => {
      (config.buildSubagentResultsContext as Mock).mockReturnValue(undefined);
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          subagentResults: undefined,
        })
      );
    });

    it('passes todo context via RunContext', async () => {
      (active.todoTracker.buildContextString as Mock).mockReturnValue('Todo: Fix bug');
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          todoContext: 'Todo: Fix bug',
        })
      );
    });

    it('passes undefined todoContext when not available', async () => {
      (active.todoTracker.buildContextString as Mock).mockReturnValue(undefined);
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          todoContext: undefined,
        })
      );
    });

    it('passes effective reasoning level from options', async () => {
      const options = createRunOptions({ reasoningLevel: 'high' });

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          reasoningLevel: 'high',
        })
      );
    });

    it('passes persisted reasoning level from sessionContext when not in options', async () => {
      (active.sessionContext.getReasoningLevel as Mock).mockReturnValue('medium');
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.agent.run).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          reasoningLevel: 'medium',
        })
      );
    });
  });

  describe('run() - User Content Building', () => {
    it('uses simple string content for text-only prompts', async () => {
      const options = createRunOptions({ prompt: 'Simple text' });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({ content: 'Simple text' })
      );
    });

    it('includes skills in message payload', async () => {
      const options = createRunOptions({
        prompt: 'Test',
        skills: [{ name: 'typescript-rules', source: 'global' }],
      });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({
          skills: [{ name: 'typescript-rules', source: 'global' }],
        })
      );
    });

    it('includes spells in message payload', async () => {
      const options = createRunOptions({
        prompt: 'Test',
        spells: [{ name: 'code-review', source: 'project' }],
      });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({
          spells: [{ name: 'code-review', source: 'project' }],
        })
      );
    });

    it('handles image attachments', async () => {
      const options = createRunOptions({
        prompt: 'What is this?',
        images: [
          { mimeType: 'image/png', data: 'base64data' },
        ],
      });

      await runner.run(active, options);

      // With images, content should be array (not simple string)
      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({ type: 'text', text: 'What is this?' }),
            expect.objectContaining({ type: 'image', mimeType: 'image/png' }),
          ]),
        })
      );
    });

    it('handles PDF attachments', async () => {
      const options = createRunOptions({
        prompt: 'Summarize this',
        attachments: [
          { mimeType: 'application/pdf', data: 'pdfdata', fileName: 'doc.pdf' },
        ],
      });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({ type: 'document', mimeType: 'application/pdf' }),
          ]),
        })
      );
    });

    it('handles text file attachments', async () => {
      const options = createRunOptions({
        prompt: 'Review this',
        attachments: [
          { mimeType: 'text/plain', data: 'file content', fileName: 'code.txt' },
        ],
      });

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.user',
        expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({ type: 'document', mimeType: 'text/plain' }),
          ]),
        })
      );
    });
  });

  describe('run() - Reasoning Level', () => {
    it('does not persist event when reasoning level not specified', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      const appendCalls = (active.sessionContext.appendEvent as Mock).mock.calls;
      const reasoningCalls = appendCalls.filter(([type]: [string]) => type === 'config.reasoning_level');
      expect(reasoningCalls).toHaveLength(0);
    });

    it('does not persist event when reasoning level unchanged', async () => {
      (active.sessionContext.getReasoningLevel as Mock).mockReturnValue('high');
      const options = createRunOptions({ reasoningLevel: 'high' });

      await runner.run(active, options);

      const appendCalls = (active.sessionContext.appendEvent as Mock).mock.calls;
      const reasoningCalls = appendCalls.filter(([type]: [string]) => type === 'config.reasoning_level');
      expect(reasoningCalls).toHaveLength(0);
    });

    it('persists reasoning level change to sessionContext and records event', async () => {
      (active.sessionContext.getReasoningLevel as Mock).mockReturnValue('low');
      const options = createRunOptions({ reasoningLevel: 'high' });

      await runner.run(active, options);

      expect(active.sessionContext.setReasoningLevel).toHaveBeenCalledWith('high');
      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'config.reasoning_level',
        expect.objectContaining({
          previousLevel: 'low',
          newLevel: 'high',
        })
      );
    });
  });

  describe('run() - Completion Handling', () => {
    it('flushes events on completion', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      // flushEvents called twice: once before execution, once after
      expect(active.sessionContext.flushEvents).toHaveBeenCalledTimes(2);
    });

    it('emits turn_complete event', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(config.emit).toHaveBeenCalledWith('agent_turn', expect.objectContaining({
        type: 'turn_complete',
        sessionId: 'sess_test123',
      }));
    });

    it('emits agent.complete event on success', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(config.emit).toHaveBeenCalledWith('agent_event', expect.objectContaining({
        type: 'agent.complete',
        sessionId: 'sess_test123',
        data: expect.objectContaining({ success: true }),
      }));
    });

    it('calls onEvent callback with turn_complete', async () => {
      const onEvent = vi.fn();
      const options = createRunOptions({ onEvent });

      await runner.run(active, options);

      expect(onEvent).toHaveBeenCalledWith(expect.objectContaining({
        type: 'turn_complete',
      }));
    });
  });

  describe('run() - Interrupt Handling', () => {
    beforeEach(() => {
      (active.agent.run as Mock).mockResolvedValue({
        success: false,
        interrupted: true,
        turns: 1,
        partialContent: 'Partial response...',
        totalTokenUsage: { inputTokens: 100, outputTokens: 25 },
      } as RunResult);
    });

    it('detects interrupted result', async () => {
      const options = createRunOptions();

      const results = await runner.run(active, options);

      expect(results[0].interrupted).toBe(true);
    });

    it('calls onEvent with turn_interrupted', async () => {
      const onEvent = vi.fn();
      const options = createRunOptions({ onEvent });

      await runner.run(active, options);

      expect(onEvent).toHaveBeenCalledWith(expect.objectContaining({
        type: 'turn_interrupted',
        data: expect.objectContaining({ interrupted: true }),
      }));
    });

    it('persists notification.interrupted event', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'notification.interrupted',
        expect.objectContaining({ turn: 1 })
      );
    });

    it('marks session as interrupted', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.wasInterrupted).toBe(true);
    });

    it('calls onAgentEnd to clear turn state', async () => {
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.onAgentEnd).toHaveBeenCalled();
    });

    it('persists partial assistant content', async () => {
      (active.sessionContext.buildCurrentTurnInterruptedContent as Mock).mockReturnValue({
        assistantContent: [{ type: 'text', text: 'Partial...' }],
        toolResultContent: [],
      });
      const options = createRunOptions();

      await runner.run(active, options);

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'message.assistant',
        expect.objectContaining({
          interrupted: true,
          stopReason: 'interrupted',
        })
      );
    });

    it('persists tool results from interrupted session', async () => {
      (active.sessionContext.buildCurrentTurnInterruptedContent as Mock).mockReturnValue({
        assistantContent: [{ type: 'tool_use', id: 'tc_1', name: 'Read', input: {} }],
        toolResultContent: [{ type: 'tool_result', tool_use_id: 'tc_1', content: 'file content', is_error: false }],
      });
      const options = createRunOptions();

      await runner.run(active, options);

      // Tool results persisted as individual tool.result events (not message.user)
      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'tool.result',
        expect.objectContaining({
          toolCallId: 'tc_1',
          content: 'file content',
          interrupted: true,
        })
      );
    });

    it('does not persist when no accumulated content', async () => {
      (active.sessionContext.buildCurrentTurnInterruptedContent as Mock).mockReturnValue({
        assistantContent: [],
        toolResultContent: [],
      });
      const options = createRunOptions();

      await runner.run(active, options);

      // Should only have message.user (initial prompt) and notification.interrupted
      const appendCalls = (active.sessionContext.appendEvent as Mock).mock.calls;
      const eventTypes = appendCalls.map(([type]) => type);
      expect(eventTypes).not.toContain('message.assistant');
    });
  });

  describe('run() - Error Handling', () => {
    const testError = new Error('Agent execution failed');

    beforeEach(() => {
      (active.agent.run as Mock).mockRejectedValue(testError);
    });

    it('persists error.agent event', async () => {
      const options = createRunOptions();

      await expect(runner.run(active, options)).rejects.toThrow('Agent execution failed');

      expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
        'error.agent',
        expect.objectContaining({
          error: 'Agent execution failed',
          recoverable: false,
        })
      );
    });

    it('emits error event via onEvent callback', async () => {
      const onEvent = vi.fn();
      const options = createRunOptions({ onEvent });

      await expect(runner.run(active, options)).rejects.toThrow();

      expect(onEvent).toHaveBeenCalledWith(expect.objectContaining({
        type: 'error',
        data: expect.objectContaining({ message: 'Agent execution failed' }),
      }));
    });

    it('emits agent.complete with success=false', async () => {
      const options = createRunOptions();

      await expect(runner.run(active, options)).rejects.toThrow();

      expect(config.emit).toHaveBeenCalledWith('agent_event', expect.objectContaining({
        type: 'agent.complete',
        data: expect.objectContaining({
          success: false,
          error: 'Agent execution failed',
        }),
      }));
    });

    it('re-throws the error', async () => {
      const options = createRunOptions();

      await expect(runner.run(active, options)).rejects.toThrow('Agent execution failed');
    });

    it('flushes events before persisting error', async () => {
      const options = createRunOptions();

      await expect(runner.run(active, options)).rejects.toThrow();

      // flushEvents should be called before error.agent is appended
      const flushCalls = (active.sessionContext.flushEvents as Mock).mock.invocationCallOrder;
      const appendCalls = (active.sessionContext.appendEvent as Mock).mock.invocationCallOrder;
      // Find the error.agent append call order
      const errorAppendIndex = (active.sessionContext.appendEvent as Mock).mock.calls.findIndex(
        ([type]) => type === 'error.agent'
      );
      if (errorAppendIndex >= 0) {
        expect(flushCalls[flushCalls.length - 1]).toBeLessThan(appendCalls[errorAppendIndex]);
      }
    });

    it('handles persistence error gracefully', async () => {
      // Make appendEvent throw when recording error.agent
      (active.sessionContext.appendEvent as Mock).mockImplementation((type) => {
        if (type === 'error.agent') {
          throw new Error('Database write failed');
        }
        return Promise.resolve({ id: 'evt_mock' });
      });
      const options = createRunOptions();

      // Should still throw the original error, not the persistence error
      await expect(runner.run(active, options)).rejects.toThrow('Agent execution failed');

      // Should emit persistence error event
      expect(config.emit).toHaveBeenCalledWith('agent_event', expect.objectContaining({
        type: 'error.persistence',
      }));
    });
  });

});

// =============================================================================
// Edge Cases and Regression Tests
// =============================================================================

describe('AgentRunner Edge Cases', () => {
  let runner: AgentRunner;
  let config: AgentRunnerConfig;
  let active: ActiveSession;

  beforeEach(() => {
    config = createMockConfig();
    runner = new AgentRunner(config);
    active = createMockActiveSession();
  });

  it('handles empty prompt', async () => {
    const options = createRunOptions({ prompt: '' });

    await runner.run(active, options);

    // Should still record a user message (empty content)
    expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
      'message.user',
      expect.any(Object)
    );
  });

  it('handles multiple runs on same session', async () => {
    const options1 = createRunOptions({ prompt: 'First' });
    const options2 = createRunOptions({ prompt: 'Second' });

    await runner.run(active, options1);
    await runner.run(active, options2);

    // Should record two separate user messages
    const userMessageCalls = (active.sessionContext.appendEvent as Mock).mock.calls.filter(
      ([type]) => type === 'message.user'
    );
    expect(userMessageCalls).toHaveLength(2);
  });

  it('handles agent returning error result (not throwing)', async () => {
    (active.agent.run as Mock).mockResolvedValue({
      success: false,
      error: 'Rate limited',
      turns: 1,
      stoppedReason: 'error',
    } as RunResult);
    const options = createRunOptions();

    const results = await runner.run(active, options);

    // Should still emit agent.complete with the error
    expect(config.emit).toHaveBeenCalledWith('agent_event', expect.objectContaining({
      type: 'agent.complete',
      data: expect.objectContaining({
        success: false,
        error: 'Rate limited',
      }),
    }));
    expect(results[0].error).toBe('Rate limited');
  });

  it('handles non-Error thrown objects', async () => {
    (active.agent.run as Mock).mockRejectedValue('string error');
    const options = createRunOptions();

    await expect(runner.run(active, options)).rejects.toBe('string error');

    expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
      'error.agent',
      expect.objectContaining({
        error: 'string error',
      })
    );
  });

  it('handles mixed content types in single run', async () => {
    const options = createRunOptions({
      prompt: 'Analyze these',
      images: [{ mimeType: 'image/png', data: 'img1' }],
      attachments: [
        { mimeType: 'application/pdf', data: 'pdf1', fileName: 'doc.pdf' },
        { mimeType: 'text/plain', data: 'txt1', fileName: 'code.txt' },
      ],
    });

    await runner.run(active, options);

    expect(active.sessionContext.appendEvent).toHaveBeenCalledWith(
      'message.user',
      expect.objectContaining({
        content: expect.arrayContaining([
          expect.objectContaining({ type: 'text' }),
          expect.objectContaining({ type: 'image' }),
          expect.objectContaining({ type: 'document', mimeType: 'application/pdf' }),
          expect.objectContaining({ type: 'document', mimeType: 'text/plain' }),
        ]),
      })
    );
  });

  it('ignores non-image items in legacy images array', async () => {
    const options = createRunOptions({
      prompt: 'Test',
      images: [
        { mimeType: 'image/png', data: 'valid' },
        { mimeType: 'application/pdf', data: 'invalid' }, // Should be ignored
      ],
    });

    await runner.run(active, options);

    const appendCall = (active.sessionContext.appendEvent as Mock).mock.calls.find(
      ([type]) => type === 'message.user'
    );
    const content = appendCall![1].content;
    const imageBlocks = content.filter((c: any) => c.type === 'image');
    expect(imageBlocks).toHaveLength(1);
  });
});
