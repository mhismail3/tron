/**
 * @fileoverview TronAgent Lifecycle Hook Integration Tests
 *
 * TDD: Tests for lifecycle hook invocations (SessionStart, SessionEnd, Stop, UserPromptSubmit).
 * Tool hooks (PreToolUse, PostToolUse) are tested in tool-executor.test.ts.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { TronAgent } from '../tron-agent.js';
import type { AgentConfig } from '../types.js';
import type { TronEvent } from '../../types/index.js';

// Mock the provider factory with a proper streaming response
vi.mock('@llm/providers/index.js', async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    createProvider: vi.fn(),
    detectProviderFromModel: vi.fn(),
  };
});

import { createProvider, detectProviderFromModel } from '@llm/providers/index.js';

describe('TronAgent Lifecycle Hooks', () => {
  let config: AgentConfig;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers({ shouldAdvanceTime: true });

    vi.mocked(detectProviderFromModel).mockReturnValue('anthropic' as any);
    vi.mocked(createProvider).mockImplementation(() => ({
      id: 'anthropic',
      model: 'claude-sonnet-4-20250514',
      stream: vi.fn().mockImplementation(async function* () {
        yield { type: 'start' };
        yield { type: 'text_start' };
        yield { type: 'text_delta', delta: 'Hello!' };
        yield { type: 'text_end', text: 'Hello!' };
        yield {
          type: 'done',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: 'Hello!' }],
          },
          stopReason: 'end_turn',
          usage: { inputTokens: 100, outputTokens: 10 },
        };
      }),
    }) as any);

    config = {
      provider: {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'test-key' },
      },
      tools: [],
      systemPrompt: 'You are a helpful assistant.',
    };
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('SessionStart hook', () => {
    it('should execute SessionStart hook at run() start', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'test-session-start',
        type: 'SessionStart',
        handler: hookHandler,
      });

      await agent.run('Hello');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'SessionStart',
          sessionId: agent.sessionId,
        })
      );
    });

    it('should include workingDirectory in SessionStart context', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config, {
        workingDirectory: '/test/project',
      });

      agent.registerHook({
        name: 'test-session-start',
        type: 'SessionStart',
        handler: hookHandler,
      });

      await agent.run('Hello');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          workingDirectory: '/test/project',
        })
      );
    });

    it('should emit hook events for SessionStart', async () => {
      const events: TronEvent[] = [];
      const agent = new TronAgent(config);

      agent.onEvent((e) => events.push(e));
      agent.registerHook({
        name: 'test-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      await agent.run('Hello');

      const triggeredEvents = events.filter((e) => e.type === 'hook_triggered');
      const completedEvents = events.filter((e) => e.type === 'hook_completed');

      // Should have at least one SessionStart hook triggered event
      expect(triggeredEvents.some((e) => 'hookEvent' in e && e.hookEvent === 'SessionStart')).toBe(true);
      expect(completedEvents.some((e) => 'hookEvent' in e && e.hookEvent === 'SessionStart')).toBe(true);
    });
  });

  describe('UserPromptSubmit hook', () => {
    it('should execute UserPromptSubmit hook after user message added', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'test-prompt-hook',
        type: 'UserPromptSubmit',
        handler: hookHandler,
      });

      await agent.run('Test prompt content');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'UserPromptSubmit',
          prompt: 'Test prompt content',
        })
      );
    });

    it('should block run when UserPromptSubmit returns block', async () => {
      const hookHandler = vi.fn().mockResolvedValue({
        action: 'block',
        reason: 'Prompt rejected by policy',
      });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'block-prompt',
        type: 'UserPromptSubmit',
        handler: hookHandler,
      });

      const result = await agent.run('Blocked content');

      expect(result.success).toBe(false);
      expect(result.error).toContain('Prompt rejected by policy');
      expect(result.turns).toBe(0);
    });

    it('should execute after SessionStart hook', async () => {
      const callOrder: string[] = [];
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'session-start',
        type: 'SessionStart',
        handler: async () => {
          callOrder.push('SessionStart');
          return { action: 'continue' };
        },
      });

      agent.registerHook({
        name: 'prompt-submit',
        type: 'UserPromptSubmit',
        handler: async () => {
          callOrder.push('UserPromptSubmit');
          return { action: 'continue' };
        },
      });

      await agent.run('Hello');

      expect(callOrder).toEqual(['SessionStart', 'UserPromptSubmit']);
    });
  });

  describe('Stop hook', () => {
    it('should execute Stop hook on successful completion', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'test-stop',
        type: 'Stop',
        handler: hookHandler,
      });

      const result = await agent.run('Hello');

      expect(result.success).toBe(true);
      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'Stop',
          stopReason: 'completed',
        })
      );
    });

    it('should execute Stop hook on blocked prompt', async () => {
      const stopHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'block-prompt',
        type: 'UserPromptSubmit',
        handler: async () => ({ action: 'block', reason: 'Blocked' }),
      });

      agent.registerHook({
        name: 'test-stop',
        type: 'Stop',
        handler: stopHandler,
      });

      await agent.run('Blocked');

      expect(stopHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'Stop',
          stopReason: 'blocked',
        })
      );
    });
  });

  describe('SessionEnd hook', () => {
    it('should execute SessionEnd hook with counts', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'test-session-end',
        type: 'SessionEnd',
        handler: hookHandler,
      });

      await agent.run('Hello');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'SessionEnd',
          messageCount: expect.any(Number),
          toolCallCount: expect.any(Number),
        })
      );
    });

    it('should execute SessionEnd after Stop hook', async () => {
      const callOrder: string[] = [];
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'stop-hook',
        type: 'Stop',
        handler: async () => {
          callOrder.push('Stop');
          return { action: 'continue' };
        },
      });

      agent.registerHook({
        name: 'session-end-hook',
        type: 'SessionEnd',
        handler: async () => {
          callOrder.push('SessionEnd');
          return { action: 'continue' };
        },
      });

      await agent.run('Hello');

      expect(callOrder).toEqual(['Stop', 'SessionEnd']);
    });
  });

  describe('hook execution order', () => {
    it('should execute lifecycle hooks in correct order', async () => {
      const callOrder: string[] = [];
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'session-start',
        type: 'SessionStart',
        handler: async () => {
          callOrder.push('SessionStart');
          return { action: 'continue' };
        },
      });

      agent.registerHook({
        name: 'prompt-submit',
        type: 'UserPromptSubmit',
        handler: async () => {
          callOrder.push('UserPromptSubmit');
          return { action: 'continue' };
        },
      });

      agent.registerHook({
        name: 'stop',
        type: 'Stop',
        handler: async () => {
          callOrder.push('Stop');
          return { action: 'continue' };
        },
      });

      agent.registerHook({
        name: 'session-end',
        type: 'SessionEnd',
        handler: async () => {
          callOrder.push('SessionEnd');
          return { action: 'continue' };
        },
      });

      await agent.run('Hello');

      expect(callOrder).toEqual(['SessionStart', 'UserPromptSubmit', 'Stop', 'SessionEnd']);
    });
  });

  describe('fail-open behavior', () => {
    it('should continue when hook throws error', async () => {
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'error-hook',
        type: 'SessionStart',
        handler: async () => {
          throw new Error('Hook crashed');
        },
      });

      // Should not throw, should continue
      const result = await agent.run('Hello');
      expect(result.success).toBe(true);
    });

    it('should continue execution when hook times out', async () => {
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'slow-hook',
        type: 'SessionStart',
        timeout: 10, // Very short timeout
        handler: async () => {
          await new Promise((resolve) => setTimeout(resolve, 1000));
          return { action: 'continue' };
        },
      });

      // Should not hang, should continue due to timeout
      const result = await agent.run('Hello');
      expect(result.success).toBe(true);
    });
  });
});
