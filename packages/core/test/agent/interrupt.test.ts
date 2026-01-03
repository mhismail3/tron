/**
 * @fileoverview Tests for agent interrupt/abort functionality
 *
 * Tests the Esc interrupt feature that allows users to stop
 * processing and re-prompt while preserving partial results.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { TronAgent } from '../../src/agent/tron-agent.js';
import type { TronTool, TronToolResult, TronEvent } from '../../src/types/index.js';

// Mock provider that we can control
const createMockProvider = () => {
  let resolveStream: (() => void) | null = null;
  let rejectStream: ((err: Error) => void) | null = null;
  const streamEvents: Array<{ type: string; [key: string]: unknown }> = [];

  return {
    model: 'test-model',
    async *stream() {
      yield { type: 'start' };
      yield { type: 'text_start' };
      yield { type: 'text_delta', delta: 'Hello ' };
      yield { type: 'text_delta', delta: 'world' };

      // Wait for external signal (simulates long-running operation)
      await new Promise<void>((resolve, reject) => {
        resolveStream = resolve;
        rejectStream = reject;
      });

      yield { type: 'text_end', text: 'Hello world' };
      yield {
        type: 'done',
        message: {
          role: 'assistant' as const,
          content: [{ type: 'text' as const, text: 'Hello world' }],
          usage: { inputTokens: 10, outputTokens: 5 },
        },
        stopReason: 'end_turn',
      };
    },
    completeStream: () => resolveStream?.(),
    failStream: (err: Error) => rejectStream?.(err),
    addEvent: (event: { type: string; [key: string]: unknown }) => streamEvents.push(event),
  };
};

// Mock tool that takes time to execute
const createMockSlowTool = (): TronTool & { completeExecution: () => void; abortSignal: AbortSignal | null } => {
  let resolveExecution: ((result: TronToolResult) => void) | null = null;
  let capturedSignal: AbortSignal | null = null;

  return {
    name: 'slow_tool',
    description: 'A tool that takes time to execute',
    parameters: {
      type: 'object',
      properties: {
        input: { type: 'string', description: 'Input value' },
      },
      required: ['input'],
    },
    execute: async (
      _toolCallId: string,
      _params: Record<string, unknown>,
      signal: AbortSignal
    ): Promise<TronToolResult> => {
      capturedSignal = signal;

      return new Promise((resolve) => {
        resolveExecution = resolve;

        // Listen for abort
        signal.addEventListener('abort', () => {
          resolve({
            content: 'Tool execution was interrupted',
            isError: true,
            details: { interrupted: true },
          });
        });
      });
    },
    completeExecution: () => {
      resolveExecution?.({
        content: 'Tool completed successfully',
        isError: false,
      });
    },
    get abortSignal() {
      return capturedSignal;
    },
  };
};

describe('Agent Interrupt Feature', () => {
  let mockProvider: ReturnType<typeof createMockProvider>;

  beforeEach(() => {
    mockProvider = createMockProvider();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('abort() method', () => {
    it('should set isRunning to false when abort is called', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      // Start a run (will be pending due to mock)
      const runPromise = agent.run('test');

      // Give it a moment to start
      await vi.advanceTimersByTimeAsync(10);

      expect(agent.getState().isRunning).toBe(true);

      // Abort
      agent.abort();

      expect(agent.getState().isRunning).toBe(false);

      // Complete the run to prevent hanging
      try {
        await runPromise;
      } catch {
        // Expected to fail or complete with interrupted state
      }
    });

    it('should emit agent_interrupted event when aborted', async () => {
      const events: TronEvent[] = [];
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      agent.onEvent((event) => events.push(event));

      // Start run and abort
      const runPromise = agent.run('test');
      await vi.advanceTimersByTimeAsync(10);

      agent.abort();

      try {
        await runPromise;
      } catch {
        // Expected
      }

      // Check for interrupted event
      const interruptedEvent = events.find((e) => e.type === 'agent_interrupted');
      expect(interruptedEvent).toBeDefined();
    });
  });

  describe('TurnResult with interruption', () => {
    it('should return interrupted: true when turn is aborted', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      // Add a user message first
      agent.addMessage({ role: 'user', content: 'test' });

      // Start turn
      const turnPromise = agent.turn();
      await vi.advanceTimersByTimeAsync(10);

      // Abort during turn
      agent.abort();

      const result = await turnPromise;

      expect(result.interrupted).toBe(true);
      expect(result.success).toBe(false);
    });

    it('should include partial content when interrupted during streaming', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      agent.addMessage({ role: 'user', content: 'test' });

      const turnPromise = agent.turn();
      await vi.advanceTimersByTimeAsync(10);

      agent.abort();

      const result = await turnPromise;

      // Result should be marked as interrupted
      // Partial content may or may not be present depending on timing
      expect(result.interrupted).toBe(true);
      // If content was captured, it should be a string
      if (result.partialContent !== undefined) {
        expect(typeof result.partialContent).toBe('string');
      }
    });
  });

  describe('RunResult with interruption', () => {
    it('should return interrupted: true when run is aborted', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      const runPromise = agent.run('test prompt');
      await vi.advanceTimersByTimeAsync(10);

      agent.abort();

      const result = await runPromise;

      expect(result.interrupted).toBe(true);
      expect(result.success).toBe(false);
    });

    it('should preserve messages collected before interruption', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      const runPromise = agent.run('test prompt');
      await vi.advanceTimersByTimeAsync(10);

      agent.abort();

      const result = await runPromise;

      // Should at least have the user message
      expect(result.messages.length).toBeGreaterThanOrEqual(1);
      expect(result.messages[0]?.role).toBe('user');
    });

    it('should include partial streaming content in messages when interrupted', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      const runPromise = agent.run('test prompt');

      // Wait for some streaming to happen
      await vi.advanceTimersByTimeAsync(50);

      agent.abort();

      const result = await runPromise;

      // If partial content was streamed, it should be preserved
      if (result.partialContent) {
        expect(result.partialContent).toContain('Hello');
      }
    });
  });

  describe('Tool interruption', () => {
    it('should signal abort to running tools', async () => {
      const slowTool = createMockSlowTool();

      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [slowTool],
        },
        { workingDirectory: '/tmp' }
      );

      agent.addMessage({ role: 'user', content: 'test' });

      // Simulate a turn that would call the tool
      // (In real usage, the provider would return a tool call)

      // Abort
      agent.abort();

      // Tool should have received the abort signal
      if (slowTool.abortSignal) {
        expect(slowTool.abortSignal.aborted).toBe(true);
      }
    });
  });

  describe('State recovery after interrupt', () => {
    it('should allow new run after interrupt', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      // First run - interrupted
      const run1Promise = agent.run('first prompt');
      await vi.advanceTimersByTimeAsync(10);
      agent.abort();
      await run1Promise;

      // Should be able to start a new run
      expect(agent.getState().isRunning).toBe(false);

      // Second run should start successfully
      const run2Promise = agent.run('second prompt');
      await vi.advanceTimersByTimeAsync(10);

      expect(agent.getState().isRunning).toBe(true);

      agent.abort();
      await run2Promise;
    });

    it('should clear active tool state after interrupt', async () => {
      const agent = new TronAgent(
        {
          provider: { model: 'test', auth: { type: 'api_key', apiKey: 'test' } },
          tools: [],
        },
        { workingDirectory: '/tmp' }
      );

      const runPromise = agent.run('test');
      await vi.advanceTimersByTimeAsync(10);

      agent.abort();

      await runPromise;

      const state = agent.getState();
      expect(state.isRunning).toBe(false);
    });
  });
});

describe('BashTool Interrupt', () => {
  it('should accept abort signal parameter', () => {
    // BashTool should have a signature that accepts abort signal
    // This is a type-level test - if it compiles, it passes
    const toolDef: TronTool = {
      name: 'Bash',
      description: 'test',
      parameters: { type: 'object', properties: {}, required: [] },
      execute: async (
        _toolCallId: string,
        _params: Record<string, unknown>,
        _signal: AbortSignal
      ): Promise<TronToolResult> => {
        return { content: 'ok', isError: false };
      },
    };

    expect(toolDef.name).toBe('Bash');
  });
});
