/**
 * @fileoverview AgentRunner Trace Context Tests
 *
 * Verifies that AgentRunner sets trace context correctly:
 * - Creates new traceId for each run
 * - Sets depth to 0 for root runs
 * - Subagent runs inherit parentTraceId and increment depth
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { randomUUID } from 'crypto';
import {
  getLoggingContext,
  clearLoggingContext,
  withLoggingContext,
} from '../../logging/log-context.js';
import { AgentRunner, type AgentRunnerConfig } from '../agent-runner.js';
import type { ActiveSession, AgentRunOptions } from '../types.js';
import type { RunResult } from '../../agent/types.js';

// =============================================================================
// Test Fixtures
// =============================================================================

function createMockActiveSession(): ActiveSession {
  const mockAgent = {
    run: vi.fn().mockResolvedValue({
      success: true,
      turns: 1,
      stoppedReason: 'end_turn',
      messages: [],
      totalTokenUsage: { inputTokens: 100, outputTokens: 50 },
    } as RunResult),
    setSkillContext: vi.fn(),
    setSubagentResultsContext: vi.fn(),
    setTodoContext: vi.fn(),
    setReasoningLevel: vi.fn(),
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
    lastActivity: new Date(),
    workingDirectory: '/test/project',
    model: 'claude-sonnet-4-20250514',
    currentTurn: 0,
    wasInterrupted: false,
  } as unknown as ActiveSession;
}

function createMockConfig(): AgentRunnerConfig {
  const mockSkillLoader = {
    loadSkillContextForPrompt: vi.fn().mockResolvedValue(undefined),
    transformContentForLLM: vi.fn().mockImplementation((content) => content),
  };

  return {
    skillLoader: mockSkillLoader as any,
    emit: vi.fn(),
    enterPlanMode: vi.fn().mockResolvedValue(undefined),
    isInPlanMode: vi.fn().mockReturnValue(false),
    buildSubagentResultsContext: vi.fn().mockReturnValue(undefined),
  };
}

function createRunOptions(overrides: Partial<AgentRunOptions> = {}): AgentRunOptions {
  return {
    sessionId: 'sess_test123',
    prompt: 'Hello, world!',
    ...overrides,
  };
}

// =============================================================================
// Trace Context Tests
// =============================================================================

describe('AgentRunner trace context', () => {
  let runner: AgentRunner;
  let config: AgentRunnerConfig;
  let active: ActiveSession;
  let capturedContext: ReturnType<typeof getLoggingContext> | null = null;

  beforeEach(() => {
    config = createMockConfig();
    runner = new AgentRunner(config);
    active = createMockActiveSession();
    capturedContext = null;
    clearLoggingContext();

    // Capture the logging context during agent.run()
    (active.agent.run as ReturnType<typeof vi.fn>).mockImplementation(async () => {
      capturedContext = getLoggingContext();
      return {
        success: true,
        turns: 1,
        stoppedReason: 'end_turn',
        messages: [],
        totalTokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
    });
  });

  afterEach(() => {
    clearLoggingContext();
  });

  it('sets traceId in logging context for run', async () => {
    const options = createRunOptions();

    await runner.run(active, options);

    expect(capturedContext).not.toBeNull();
    expect(capturedContext!.traceId).toBeDefined();
    expect(capturedContext!.traceId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    );
  });

  it('sets depth to 0 for root agent runs', async () => {
    const options = createRunOptions();

    await runner.run(active, options);

    expect(capturedContext).not.toBeNull();
    expect(capturedContext!.depth).toBe(0);
    expect(capturedContext!.parentTraceId).toBeNull();
  });

  it('traceId is different for each run', async () => {
    const options = createRunOptions();
    const traceIds: string[] = [];

    // Capture trace ID from each run
    (active.agent.run as ReturnType<typeof vi.fn>).mockImplementation(async () => {
      const ctx = getLoggingContext();
      if (ctx.traceId) traceIds.push(ctx.traceId);
      return {
        success: true,
        turns: 1,
        stoppedReason: 'end_turn',
        messages: [],
        totalTokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
    });

    await runner.run(active, options);
    await runner.run(active, options);
    await runner.run(active, options);

    expect(traceIds).toHaveLength(3);
    expect(new Set(traceIds).size).toBe(3); // All unique
  });

  it('sessionId is set alongside traceId', async () => {
    const options = createRunOptions({ sessionId: 'sess_with_trace' });

    await runner.run(active, options);

    expect(capturedContext).not.toBeNull();
    expect(capturedContext!.sessionId).toBe('sess_with_trace');
    expect(capturedContext!.traceId).toBeDefined();
  });

  it('subagent run inherits parentTraceId from caller context', async () => {
    const parentTraceId = randomUUID();
    const options = createRunOptions();

    // Simulate running within an existing trace context (as if called from parent agent)
    await withLoggingContext({ traceId: parentTraceId, depth: 0 }, async () => {
      await runner.run(active, options);
    });

    expect(capturedContext).not.toBeNull();
    // Should have a NEW traceId (not the parent's)
    expect(capturedContext!.traceId).toBeDefined();
    expect(capturedContext!.traceId).not.toBe(parentTraceId);
    // Should link to parent
    expect(capturedContext!.parentTraceId).toBe(parentTraceId);
    // Should be depth 1 (one level deeper)
    expect(capturedContext!.depth).toBe(1);
  });

  it('deeply nested subagent runs have correct depth', async () => {
    const rootTraceId = randomUUID();
    const level1TraceId = randomUUID();
    const options = createRunOptions();

    // Simulate nested trace contexts (grandparent -> parent -> child)
    await withLoggingContext({ traceId: rootTraceId, depth: 0 }, async () => {
      await withLoggingContext({ traceId: level1TraceId, parentTraceId: rootTraceId, depth: 1 }, async () => {
        await runner.run(active, options);
      });
    });

    expect(capturedContext).not.toBeNull();
    // Child should be at depth 2
    expect(capturedContext!.depth).toBe(2);
    // Child's parent should be the level1 trace
    expect(capturedContext!.parentTraceId).toBe(level1TraceId);
  });

  it('trace context persists through entire agent execution', async () => {
    const options = createRunOptions();
    const contextsDuringExecution: ReturnType<typeof getLoggingContext>[] = [];

    // Capture context at multiple points during execution
    (active.sessionContext.flushEvents as ReturnType<typeof vi.fn>).mockImplementation(async () => {
      contextsDuringExecution.push({ ...getLoggingContext() });
    });

    (active.agent.run as ReturnType<typeof vi.fn>).mockImplementation(async () => {
      contextsDuringExecution.push({ ...getLoggingContext() });
      return {
        success: true,
        turns: 1,
        stoppedReason: 'end_turn',
        messages: [],
        totalTokenUsage: { inputTokens: 100, outputTokens: 50 },
      };
    });

    await runner.run(active, options);

    // All captured contexts should have the same traceId
    expect(contextsDuringExecution.length).toBeGreaterThanOrEqual(2);
    const traceId = contextsDuringExecution[0].traceId;
    expect(traceId).toBeDefined();
    expect(contextsDuringExecution.every(ctx => ctx.traceId === traceId)).toBe(true);
  });
});
