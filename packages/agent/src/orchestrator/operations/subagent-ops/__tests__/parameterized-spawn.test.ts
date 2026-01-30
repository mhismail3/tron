/**
 * @fileoverview Tests for Parameterized Subagent Spawning
 *
 * TDD tests for the extended subagent spawning capabilities:
 * 1. Custom system prompt support
 * 2. Tool denial configuration (denyAll, specific tools)
 * 3. Model specification
 *
 * These tests verify that SpawnHandler properly passes parameters
 * to createSession for subagent creation.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { SpawnHandler, createSpawnHandler, type SpawnHandlerDeps } from '../spawn-handler.js';
import type { SpawnSubagentParams } from '../../../../tools/subagent/index.js';
import type { ToolDenialConfig } from '../../../../tools/subagent/tool-denial.js';

// =============================================================================
// Test Fixtures
// =============================================================================

function createMockDeps(overrides: Partial<SpawnHandlerDeps> = {}): SpawnHandlerDeps {
  const mockActiveSession = {
    sessionId: 'sess_parent',
    workingDirectory: '/tmp/test',
    model: 'claude-sonnet-4-20250514',
    subagentTracker: {
      spawn: vi.fn(),
      updateStatus: vi.fn(),
      complete: vi.fn(),
      fail: vi.fn(),
      waitFor: vi.fn().mockResolvedValue({
        success: true,
        output: 'Summarized result from subagent',
        summary: 'Test summary',
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      }),
    },
  };

  return {
    eventStore: {
      updateSessionSpawnInfo: vi.fn(),
      getSession: vi.fn().mockResolvedValue({
        id: 'sess_sub',
        turnCount: 1,
        totalInputTokens: 100,
        totalOutputTokens: 50,
        headEventId: 'evt_123',
      }),
      getAncestors: vi.fn().mockResolvedValue([
        {
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Summarized result' }],
          },
        },
      ]),
      getDbPath: () => '/tmp/test.db',
    } as any,
    getActiveSession: vi.fn().mockReturnValue(mockActiveSession),
    createSession: vi.fn().mockResolvedValue({
      sessionId: 'sess_sub_123',
      workingDirectory: '/tmp/test',
      model: 'claude-haiku-4-5-20251001',
    }),
    runAgent: vi.fn().mockResolvedValue(undefined),
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
    ...overrides,
  };
}

// =============================================================================
// Tests: System Prompt Support
// =============================================================================

describe('SpawnHandler - System Prompt Support', () => {
  let handler: SpawnHandler;
  let deps: SpawnHandlerDeps;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createSpawnHandler(deps);
  });

  it('passes systemPrompt to createSession when provided', async () => {
    const params: SpawnSubagentParams = {
      task: 'Summarize this content',
      systemPrompt: 'You are a content summarizer. Be concise.',
      model: 'claude-haiku-4-5-20251001',
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.systemPrompt).toBe('You are a content summarizer. Be concise.');
  });

  it('does not pass systemPrompt when not provided', async () => {
    const params: SpawnSubagentParams = {
      task: 'Do something',
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.systemPrompt).toBeUndefined();
  });
});

// =============================================================================
// Tests: Tool Denial Configuration
// =============================================================================

describe('SpawnHandler - Tool Denial Configuration', () => {
  let handler: SpawnHandler;
  let deps: SpawnHandlerDeps;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createSpawnHandler(deps);
  });

  it('passes toolDenials to createSession when provided', async () => {
    const toolDenials: ToolDenialConfig = {
      tools: ['Bash', 'Write'],
    };
    const params: SpawnSubagentParams = {
      task: 'Read and analyze files',
      toolDenials,
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.toolDenials).toEqual(toolDenials);
  });

  it('passes denyAll toolDenials for text-only agents', async () => {
    const toolDenials: ToolDenialConfig = { denyAll: true };
    const params: SpawnSubagentParams = {
      task: 'Just generate text, no tools needed',
      toolDenials,
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.toolDenials).toEqual({ denyAll: true });
  });

  it('does not pass toolDenials when not specified (all tools allowed)', async () => {
    const params: SpawnSubagentParams = {
      task: 'Use all default tools',
      // toolDenials: undefined - not specified
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.toolDenials).toBeUndefined();
  });
});

// =============================================================================
// Tests: Model Specification
// =============================================================================

describe('SpawnHandler - Model Specification', () => {
  let handler: SpawnHandler;
  let deps: SpawnHandlerDeps;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createSpawnHandler(deps);
  });

  it('uses specified model when provided', async () => {
    const params: SpawnSubagentParams = {
      task: 'Summarize content',
      model: 'claude-haiku-4-5-20251001',
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.model).toBe('claude-haiku-4-5-20251001');
  });

  it('uses parent model when not specified', async () => {
    const params: SpawnSubagentParams = {
      task: 'Use parent model',
    };

    await handler.spawnSubsession('sess_parent', params);

    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.model).toBe('claude-sonnet-4-20250514');
  });
});

// =============================================================================
// Tests: Combined Parameters (Integration-style)
// =============================================================================

describe('SpawnHandler - Combined Parameters for Summarization', () => {
  let handler: SpawnHandler;
  let deps: SpawnHandlerDeps;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createSpawnHandler(deps);
  });

  it('supports spawning a no-tools Haiku subagent with custom system prompt', async () => {
    // This is the exact use case for WebFetch summarization
    const params: SpawnSubagentParams = {
      task: 'Analyze this content and answer the question: What is the main topic?\n\nContent:\n# Hello World\nThis is a test document.',
      systemPrompt: 'You are a web content analyzer. Answer questions about the provided content concisely and accurately. Do not make up information not present in the content.',
      model: 'claude-haiku-4-5-20251001',
      toolDenials: { denyAll: true }, // No tools - just text generation
      maxTurns: 1, // Single turn for simple summarization
      blocking: true, // Wait for result
      timeout: 30000, // 30 second timeout
    };

    const result = await handler.spawnSubsession('sess_parent', params);

    expect(result.success).toBe(true);
    expect(result.sessionId).toBeDefined();

    // Verify createSession was called with correct options
    expect(deps.createSession).toHaveBeenCalledTimes(1);
    const createSessionCall = (deps.createSession as any).mock.calls[0][0];

    expect(createSessionCall.model).toBe('claude-haiku-4-5-20251001');
    expect(createSessionCall.systemPrompt).toBe('You are a web content analyzer. Answer questions about the provided content concisely and accurately. Do not make up information not present in the content.');
    expect(createSessionCall.toolDenials).toEqual({ denyAll: true });
    expect(createSessionCall.parentSessionId).toBe('sess_parent');
  });

  it('includes all subagent spawn parameters in spawned event', async () => {
    const params: SpawnSubagentParams = {
      task: 'Test task',
      systemPrompt: 'Custom prompt',
      model: 'claude-haiku-4-5-20251001',
      toolDenials: { denyAll: true },
      maxTurns: 3,
    };

    await handler.spawnSubsession('sess_parent', params);

    // Verify event payload includes new parameters
    expect(deps.appendEventLinearized).toHaveBeenCalled();
    const eventCall = (deps.appendEventLinearized as any).mock.calls[0];
    const eventPayload = eventCall[2];

    expect(eventPayload.systemPrompt).toBe('Custom prompt');
    expect(eventPayload.toolDenials).toEqual({ denyAll: true });
    expect(eventPayload.maxTurns).toBe(3);
  });

  it('supports granular tool denials with patterns', async () => {
    const toolDenials: ToolDenialConfig = {
      tools: ['SpawnSubagent'], // No nested spawning
      rules: [
        {
          tool: 'Bash',
          denyPatterns: [
            { parameter: 'command', patterns: ['rm\\s+-rf', 'sudo'] },
          ],
          message: 'Dangerous commands not allowed',
        },
      ],
    };

    const params: SpawnSubagentParams = {
      task: 'Safe file operations only',
      toolDenials,
    };

    await handler.spawnSubsession('sess_parent', params);

    const createSessionCall = (deps.createSession as any).mock.calls[0][0];
    expect(createSessionCall.toolDenials).toEqual(toolDenials);
    expect(createSessionCall.toolDenials.rules).toHaveLength(1);
    expect(createSessionCall.toolDenials.rules[0].tool).toBe('Bash');
  });
});
