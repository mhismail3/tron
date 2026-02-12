/**
 * @fileoverview Tests for hook execution engine
 *
 * TDD: Tests for hook registration and execution
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HookEngine } from '../engine.js';
import type { HookDefinition, PreToolHookContext, HookResult } from '../types.js';

describe('HookEngine', () => {
  let engine: HookEngine;

  beforeEach(() => {
    engine = new HookEngine();
  });

  describe('registration', () => {
    it('should register a hook', () => {
      const hook: HookDefinition = {
        name: 'test-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      };

      engine.register(hook);

      const hooks = engine.getHooks('PreToolUse');
      expect(hooks).toHaveLength(1);
      expect(hooks[0].name).toBe('test-hook');
    });

    it('should register multiple hooks', () => {
      engine.register({
        name: 'hook-1',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      engine.register({
        name: 'hook-2',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      expect(engine.getHooks('PreToolUse')).toHaveLength(2);
    });

    it('should unregister a hook', () => {
      engine.register({
        name: 'test-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      engine.unregister('test-hook');

      expect(engine.getHooks('PreToolUse')).toHaveLength(0);
    });

    it('should not duplicate hook names', () => {
      engine.register({
        name: 'test-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      engine.register({
        name: 'test-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'block', reason: 'blocked' }),
      });

      // Should replace
      expect(engine.getHooks('PreToolUse')).toHaveLength(1);
    });

    it('should set default priority to 0', () => {
      engine.register({
        name: 'no-priority',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.getHooks('PreToolUse');
      expect(hooks[0].priority).toBe(0);
    });

    it('should set registeredAt timestamp', () => {
      const before = new Date().toISOString();
      engine.register({
        name: 'timestamped',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });
      const after = new Date().toISOString();

      const hooks = engine.getHooks('PreToolUse');
      expect(hooks[0].registeredAt).toBeDefined();
      expect(hooks[0].registeredAt >= before).toBe(true);
      expect(hooks[0].registeredAt <= after).toBe(true);
    });

    it('should force blocking mode for PreToolUse hooks', () => {
      engine.register({
        name: 'bg-pre',
        type: 'PreToolUse',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.getHooks('PreToolUse');
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should force blocking mode for UserPromptSubmit hooks', () => {
      engine.register({
        name: 'bg-prompt',
        type: 'UserPromptSubmit',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.getHooks('UserPromptSubmit');
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should force blocking mode for PreCompact hooks', () => {
      engine.register({
        name: 'bg-compact',
        type: 'PreCompact',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.getHooks('PreCompact');
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should allow background mode for PostToolUse hooks', () => {
      engine.register({
        name: 'bg-post',
        type: 'PostToolUse',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.getHooks('PostToolUse');
      expect(hooks[0].mode).toBe('background');
    });
  });

  describe('execution', () => {
    it('should execute hooks in priority order', async () => {
      const order: number[] = [];

      engine.register({
        name: 'low-priority',
        type: 'PreToolUse',
        priority: 10,
        handler: async () => {
          order.push(10);
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'high-priority',
        type: 'PreToolUse',
        priority: 100,
        handler: async () => {
          order.push(100);
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'medium-priority',
        type: 'PreToolUse',
        priority: 50,
        handler: async () => {
          order.push(50);
          return { action: 'continue' };
        },
      });

      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_1',
      };

      await engine.execute('PreToolUse', context);

      // Higher priority first
      expect(order).toEqual([100, 50, 10]);
    });

    it('should stop on block result', async () => {
      const executed: string[] = [];

      engine.register({
        name: 'blocker',
        type: 'PreToolUse',
        priority: 100,
        handler: async () => {
          executed.push('blocker');
          return { action: 'block', reason: 'Blocked!' };
        },
      });

      engine.register({
        name: 'after-blocker',
        type: 'PreToolUse',
        priority: 50,
        handler: async () => {
          executed.push('after-blocker');
          return { action: 'continue' };
        },
      });

      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Bash',
        toolArguments: { command: 'rm -rf /' },
        toolCallId: 'tool_1',
      };

      const result = await engine.execute('PreToolUse', context);

      expect(result.action).toBe('block');
      expect(executed).toEqual(['blocker']);
    });

    it('should apply filter function', async () => {
      const executed: string[] = [];

      engine.register({
        name: 'bash-only',
        type: 'PreToolUse',
        filter: (ctx) => (ctx as PreToolHookContext).toolName === 'Bash',
        handler: async () => {
          executed.push('bash-only');
          return { action: 'continue' };
        },
      });

      // Execute with Bash
      await engine.execute('PreToolUse', {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Bash',
        toolArguments: {},
        toolCallId: 'tool_1',
      });

      // Execute with Read (should not trigger hook)
      await engine.execute('PreToolUse', {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_2',
      });

      expect(executed).toEqual(['bash-only']);
    });

    it('should handle hook timeout', async () => {
      engine.register({
        name: 'slow-hook',
        type: 'PreToolUse',
        timeout: 50,
        handler: async () => {
          await new Promise(resolve => setTimeout(resolve, 200));
          return { action: 'continue' };
        },
      });

      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_1',
      };

      const result = await engine.execute('PreToolUse', context);

      // Should continue on timeout (fail-open)
      expect(result.action).toBe('continue');
    });

    it('should handle hook errors gracefully', async () => {
      engine.register({
        name: 'error-hook',
        type: 'PreToolUse',
        handler: async () => {
          throw new Error('Hook crashed');
        },
      });

      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_1',
      };

      const result = await engine.execute('PreToolUse', context);

      // Should continue on error (fail-open)
      expect(result.action).toBe('continue');
    });

    it('should return continue when no hooks registered', async () => {
      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_1',
      };

      const result = await engine.execute('PreToolUse', context);

      expect(result.action).toBe('continue');
    });

    it('should collect modifications from multiple hooks', async () => {
      engine.register({
        name: 'modifier-1',
        type: 'PreToolUse',
        priority: 100,
        handler: async () => ({
          action: 'modify',
          modifications: { arg1: 'value1' },
        }),
      });

      engine.register({
        name: 'modifier-2',
        type: 'PreToolUse',
        priority: 50,
        handler: async () => ({
          action: 'modify',
          modifications: { arg2: 'value2' },
        }),
      });

      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Bash',
        toolArguments: {},
        toolCallId: 'tool_1',
      };

      const result = await engine.execute('PreToolUse', context);

      expect(result.action).toBe('modify');
      expect(result.modifications).toHaveProperty('arg1', 'value1');
      expect(result.modifications).toHaveProperty('arg2', 'value2');
    });
  });

  describe('utility methods', () => {
    it('should list all registered hooks', () => {
      engine.register({
        name: 'hook-1',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      engine.register({
        name: 'hook-2',
        type: 'PostToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      const allHooks = engine.listHooks();
      expect(allHooks).toHaveLength(2);
    });

    it('should clear all hooks', () => {
      engine.register({
        name: 'hook-1',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      engine.clear();

      expect(engine.listHooks()).toHaveLength(0);
    });
  });
});
