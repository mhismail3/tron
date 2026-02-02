/**
 * @fileoverview TronAgent Turn Context Tests
 *
 * Verifies that TronAgent updates the turn number in logging context
 * when executing turns.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  getLoggingContext,
  withLoggingContext,
  setLoggingContext,
  clearLoggingContext,
} from '@infrastructure/logging/log-context.js';
import { TronAgent } from '../tron-agent.js';
import type { AgentConfig } from '../types.js';

// =============================================================================
// Test Fixtures
// =============================================================================

function createMinimalAgentConfig(): AgentConfig {
  return {
    provider: {
      type: 'anthropic',
      model: 'claude-sonnet-4-20250514',
      auth: { apiKey: 'test-api-key' },
    },
    systemPrompt: 'You are a test assistant.',
    tools: [],
    maxTokens: 1024,
    maxTurns: 10,
  };
}

// =============================================================================
// Turn Context Tests
// =============================================================================

describe('TronAgent turn context', () => {
  let agent: TronAgent;

  beforeEach(() => {
    clearLoggingContext();
  });

  afterEach(() => {
    clearLoggingContext();
  });

  it('updates turn number in logging context during turn execution', async () => {
    const config = createMinimalAgentConfig();
    agent = new TronAgent(config);

    // Track all context updates observed during execution
    let capturedTurn: number | undefined;

    // Mock the turn runner to capture the context
    // @ts-expect-error - accessing private turnRunner for testing
    const originalExecute = agent.turnRunner.execute.bind(agent.turnRunner);
    // @ts-expect-error - accessing private turnRunner for testing
    agent.turnRunner.execute = vi.fn().mockImplementation(async (options) => {
      // Capture the logging context during turn execution
      capturedTurn = getLoggingContext().turn;
      // Return a successful result
      return {
        success: true,
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 10, outputTokens: 5 },
        toolCallsExecuted: 0,
      };
    });

    // Add a user message first
    agent.addMessage({ role: 'user', content: 'Hi' });

    // Run within a trace context to simulate real execution flow
    // (AgentRunner normally sets this up)
    await withLoggingContext({ traceId: 'test-trace', depth: 0 }, async () => {
      await agent.turn();
    });

    // Turn should be 1 after first turn
    expect(capturedTurn).toBe(1);
  });

  it('turn number increments with each turn', async () => {
    const config = createMinimalAgentConfig();
    agent = new TronAgent(config);

    const capturedTurns: number[] = [];

    // @ts-expect-error - accessing private turnRunner for testing
    agent.turnRunner.execute = vi.fn().mockImplementation(async () => {
      const turn = getLoggingContext().turn;
      if (turn !== undefined) {
        capturedTurns.push(turn);
      }
      return {
        success: true,
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 10, outputTokens: 5 },
        toolCallsExecuted: 0,
      };
    });

    agent.addMessage({ role: 'user', content: 'Hi' });

    await withLoggingContext({ traceId: 'test-trace', depth: 0 }, async () => {
      await agent.turn();
      await agent.turn();
      await agent.turn();
    });

    expect(capturedTurns).toEqual([1, 2, 3]);
  });

  it('turn context works with existing traceId', async () => {
    const config = createMinimalAgentConfig();
    agent = new TronAgent(config);

    let capturedContext: ReturnType<typeof getLoggingContext> | null = null;

    // @ts-expect-error - accessing private turnRunner for testing
    agent.turnRunner.execute = vi.fn().mockImplementation(async () => {
      capturedContext = { ...getLoggingContext() };
      return {
        success: true,
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 10, outputTokens: 5 },
        toolCallsExecuted: 0,
      };
    });

    agent.addMessage({ role: 'user', content: 'Hi' });

    const traceId = 'test-trace-with-turn';
    await withLoggingContext({ traceId, depth: 0 }, async () => {
      await agent.turn();
    });

    expect(capturedContext).not.toBeNull();
    expect(capturedContext!.traceId).toBe(traceId);
    expect(capturedContext!.turn).toBe(1);
  });

  it('turn context updates are visible to nested operations', async () => {
    const config = createMinimalAgentConfig();
    agent = new TronAgent(config);

    const contextSnapshots: { turn?: number; traceId?: string }[] = [];

    // @ts-expect-error - accessing private turnRunner for testing
    agent.turnRunner.execute = vi.fn().mockImplementation(async () => {
      // Simulate nested operations during turn execution
      contextSnapshots.push({ ...getLoggingContext() });

      // Simulate tool execution that also reads context
      await Promise.resolve();
      contextSnapshots.push({ ...getLoggingContext() });

      return {
        success: true,
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 10, outputTokens: 5 },
        toolCallsExecuted: 0,
      };
    });

    agent.addMessage({ role: 'user', content: 'Hi' });

    const traceId = 'test-trace-nested';
    await withLoggingContext({ traceId, depth: 0 }, async () => {
      await agent.turn();
    });

    // All snapshots should have consistent turn and trace
    expect(contextSnapshots.length).toBeGreaterThanOrEqual(2);
    expect(contextSnapshots.every(s => s.turn === 1)).toBe(true);
    expect(contextSnapshots.every(s => s.traceId === traceId)).toBe(true);
  });

  it('turn context does not affect outer context after turn completes', async () => {
    const config = createMinimalAgentConfig();
    agent = new TronAgent(config);

    // @ts-expect-error - accessing private turnRunner for testing
    agent.turnRunner.execute = vi.fn().mockImplementation(async () => {
      return {
        success: true,
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 10, outputTokens: 5 },
        toolCallsExecuted: 0,
      };
    });

    agent.addMessage({ role: 'user', content: 'Hi' });

    // Note: updateLoggingContext modifies the current context in place,
    // but since it's within withLoggingContext, the outer context is not affected
    // after the withLoggingContext block completes.
    let contextAfterTurn: ReturnType<typeof getLoggingContext> | null = null;

    await withLoggingContext({ traceId: 'test-trace' }, async () => {
      await agent.turn();
      contextAfterTurn = { ...getLoggingContext() };
    });

    // The turn context should persist within the same withLoggingContext block
    expect(contextAfterTurn!.turn).toBe(1);

    // But outside, context should be clean
    const contextAfterBlock = getLoggingContext();
    expect(contextAfterBlock.turn).toBeUndefined();
    expect(contextAfterBlock.traceId).toBeUndefined();
  });
});
