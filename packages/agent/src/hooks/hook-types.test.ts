/**
 * @fileoverview Tests for hook types
 *
 * TDD: Tests for the hook system type definitions
 */

import { describe, it, expect } from 'vitest';
import type {
  HookType,
  HookResult,
  HookContext,
  Hook,
  HookDefinition,
  PreToolHookContext,
  PostToolHookContext,
  StopHookContext,
  NotificationHookContext,
} from '../../src/hooks/types.js';

describe('Hook Types', () => {
  describe('HookType', () => {
    it('should define all hook types', () => {
      const types: HookType[] = [
        'PreToolUse',
        'PostToolUse',
        'Stop',
        'SubagentStop',
        'SessionStart',
        'SessionEnd',
        'UserPromptSubmit',
        'PreCompact',
        'Notification',
      ];

      expect(types).toHaveLength(9);
    });
  });

  describe('HookResult', () => {
    it('should define continue result', () => {
      const result: HookResult = {
        action: 'continue',
      };

      expect(result.action).toBe('continue');
    });

    it('should define block result', () => {
      const result: HookResult = {
        action: 'block',
        reason: 'Dangerous operation blocked',
      };

      expect(result.action).toBe('block');
      expect(result.reason).toBeTruthy();
    });

    it('should define modify result', () => {
      const result: HookResult = {
        action: 'modify',
        modifications: {
          command: 'echo "safe command"',
        },
      };

      expect(result.action).toBe('modify');
      expect(result.modifications).toHaveProperty('command');
    });

    it('should support optional message', () => {
      const result: HookResult = {
        action: 'continue',
        message: 'Hook approved the action',
      };

      expect(result.message).toBe('Hook approved the action');
    });
  });

  describe('HookContext', () => {
    it('should define base context structure', () => {
      const context: HookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
      };

      expect(context.hookType).toBe('PreToolUse');
      expect(context.sessionId).toBeTruthy();
      expect(context.timestamp).toBeTruthy();
    });
  });

  describe('PreToolHookContext', () => {
    it('should include tool information', () => {
      const context: PreToolHookContext = {
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Bash',
        toolArguments: {
          command: 'ls -la',
        },
        toolCallId: 'tool_abc',
      };

      expect(context.toolName).toBe('Bash');
      expect(context.toolArguments).toHaveProperty('command');
    });
  });

  describe('PostToolHookContext', () => {
    it('should include tool result', () => {
      const context: PostToolHookContext = {
        hookType: 'PostToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Bash',
        toolCallId: 'tool_abc',
        result: {
          content: 'file1.txt\nfile2.txt',
          isError: false,
        },
        duration: 150,
      };

      expect(context.result).toBeDefined();
      expect(context.result.isError).toBe(false);
      expect(context.duration).toBe(150);
    });
  });

  describe('StopHookContext', () => {
    it('should include stop reason', () => {
      const context: StopHookContext = {
        hookType: 'Stop',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        stopReason: 'end_turn',
        finalMessage: 'Task completed successfully',
      };

      expect(context.stopReason).toBe('end_turn');
      expect(context.finalMessage).toBeTruthy();
    });
  });

  describe('NotificationHookContext', () => {
    it('should include notification details', () => {
      const context: NotificationHookContext = {
        hookType: 'Notification',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        level: 'info',
        title: 'Build complete',
        body: 'All tests passed',
      };

      expect(context.level).toBe('info');
      expect(context.title).toBe('Build complete');
    });
  });

  describe('HookDefinition', () => {
    it('should define hook with handler', () => {
      const hook: HookDefinition = {
        name: 'block-rm-rf',
        type: 'PreToolUse',
        priority: 100,
        handler: async (context) => ({
          action: 'continue',
        }),
      };

      expect(hook.name).toBe('block-rm-rf');
      expect(hook.type).toBe('PreToolUse');
      expect(hook.priority).toBe(100);
      expect(typeof hook.handler).toBe('function');
    });

    it('should support optional description', () => {
      const hook: HookDefinition = {
        name: 'test-hook',
        type: 'PostToolUse',
        description: 'Logs tool execution time',
        handler: async () => ({ action: 'continue' }),
      };

      expect(hook.description).toBe('Logs tool execution time');
    });

    it('should support filter function', () => {
      const hook: HookDefinition = {
        name: 'bash-only-hook',
        type: 'PreToolUse',
        filter: (context) => context.toolName === 'Bash',
        handler: async () => ({ action: 'continue' }),
      };

      expect(typeof hook.filter).toBe('function');
    });

    it('should support timeout', () => {
      const hook: HookDefinition = {
        name: 'slow-hook',
        type: 'PreToolUse',
        timeout: 5000,
        handler: async () => ({ action: 'continue' }),
      };

      expect(hook.timeout).toBe(5000);
    });
  });

  describe('Hook interface', () => {
    it('should define execute method', async () => {
      const hook: Hook = {
        name: 'test-hook',
        type: 'PreToolUse',
        async execute(context) {
          return { action: 'continue' };
        },
      };

      const result = await hook.execute({
        hookType: 'PreToolUse',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {},
        toolName: 'Read',
        toolArguments: {},
        toolCallId: 'tool_1',
      });

      expect(result.action).toBe('continue');
    });
  });
});
