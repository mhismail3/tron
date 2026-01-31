/**
 * @fileoverview Tests for HookEngine.executeWithEvents()
 *
 * TDD: These tests were written first, before implementing the method.
 * The executeWithEvents method centralizes hook execution with automatic
 * event emission, eliminating duplicated code in TronAgent, ToolExecutor,
 * and CompactionHandler.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { HookEngine } from '../engine.js';
import type { TronEvent } from '../../types/index.js';
import {
  createSessionStartContext,
  createPreToolUseContext,
  createUserPromptSubmitContext,
  createPreCompactContext,
} from './context-factories.js';

describe('HookEngine.executeWithEvents', () => {
  let engine: HookEngine;

  beforeEach(() => {
    engine = new HookEngine();
  });

  describe('event emission', () => {
    it('should emit hook_triggered and hook_completed events when hooks exist', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'test-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(events).toHaveLength(2);
      expect(events[0].type).toBe('hook_triggered');
      expect(events[1].type).toBe('hook_completed');
    });

    it('should not emit events when no hooks registered', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(events).toHaveLength(0);
    });

    it('should include hookNames array in events', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'hook-a',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });
      engine.register({
        name: 'hook-b',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      const triggered = events.find(e => e.type === 'hook_triggered');
      expect(triggered).toBeDefined();
      if (triggered && triggered.type === 'hook_triggered') {
        expect(triggered.hookNames).toContain('hook-a');
        expect(triggered.hookNames).toContain('hook-b');
      }
    });

    it('should include hookEvent type in events', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'test-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      const triggered = events.find(e => e.type === 'hook_triggered');
      expect(triggered).toBeDefined();
      if (triggered && triggered.type === 'hook_triggered') {
        expect(triggered.hookEvent).toBe('SessionStart');
      }
    });
  });

  describe('duration tracking', () => {
    it('should include duration in hook_completed event', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'slow-hook',
        type: 'SessionStart',
        handler: async () => {
          await new Promise(r => setTimeout(r, 50));
          return { action: 'continue' };
        },
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      const completed = events.find(e => e.type === 'hook_completed');
      expect(completed).toBeDefined();
      if (completed && completed.type === 'hook_completed') {
        expect(completed.duration).toBeGreaterThanOrEqual(50);
      }
    });
  });

  describe('tool context', () => {
    it('should include tool metadata in events for PreToolUse', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'tool-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createPreToolUseContext({
        sessionId: 'sess_123',
        toolName: 'Bash',
        toolCallId: 'call_456',
      });
      await engine.executeWithEvents('PreToolUse', context, mockEmitter);

      const triggered = events.find(e => e.type === 'hook_triggered');
      expect(triggered).toBeDefined();
      if (triggered && triggered.type === 'hook_triggered') {
        expect(triggered.toolName).toBe('Bash');
        expect(triggered.toolCallId).toBe('call_456');
      }
    });

    it('should include tool metadata in hook_completed for PreToolUse', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'tool-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createPreToolUseContext({
        sessionId: 'sess_123',
        toolName: 'Read',
        toolCallId: 'call_789',
      });
      await engine.executeWithEvents('PreToolUse', context, mockEmitter);

      const completed = events.find(e => e.type === 'hook_completed');
      expect(completed).toBeDefined();
      if (completed && completed.type === 'hook_completed') {
        expect(completed.toolName).toBe('Read');
        expect(completed.toolCallId).toBe('call_789');
      }
    });
  });

  describe('result handling', () => {
    it('should return block result from hooks', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'blocker',
        type: 'UserPromptSubmit',
        handler: async () => ({ action: 'block', reason: 'Dangerous' }),
      });

      const context = createUserPromptSubmitContext({
        sessionId: 'sess_123',
        prompt: 'test',
      });
      const result = await engine.executeWithEvents('UserPromptSubmit', context, mockEmitter);

      expect(result.action).toBe('block');
      expect(result.reason).toBe('Dangerous');
    });

    it('should include result action in hook_completed event', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'blocker',
        type: 'UserPromptSubmit',
        handler: async () => ({ action: 'block', reason: 'Not allowed' }),
      });

      const context = createUserPromptSubmitContext({
        sessionId: 'sess_123',
        prompt: 'test',
      });
      await engine.executeWithEvents('UserPromptSubmit', context, mockEmitter);

      const completed = events.find(e => e.type === 'hook_completed');
      expect(completed).toBeDefined();
      if (completed && completed.type === 'hook_completed') {
        expect(completed.result).toBe('block');
        expect(completed.reason).toBe('Not allowed');
      }
    });

    it('should return modify result with modifications', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'modifier',
        type: 'PreToolUse',
        handler: async () => ({
          action: 'modify',
          modifications: { command: 'ls -la' },
        }),
      });

      const context = createPreToolUseContext({
        sessionId: 'sess_123',
        toolName: 'Bash',
        toolCallId: 'call_1',
      });
      const result = await engine.executeWithEvents('PreToolUse', context, mockEmitter);

      expect(result.action).toBe('modify');
      expect(result.modifications).toHaveProperty('command', 'ls -la');
    });
  });

  describe('error handling', () => {
    it('should continue and return continue on hook error (fail-open)', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'error-hook',
        type: 'SessionStart',
        handler: async () => {
          throw new Error('Hook crashed');
        },
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      const result = await engine.executeWithEvents('SessionStart', context, mockEmitter);

      // Should NOT throw, should return continue (fail-open)
      expect(result.action).toBe('continue');
    });

    it('should still emit events when hook errors', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'error-hook',
        type: 'SessionStart',
        handler: async () => {
          throw new Error('Hook crashed');
        },
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      // Events should still be emitted
      expect(events).toHaveLength(2);
      expect(events[0].type).toBe('hook_triggered');
      expect(events[1].type).toBe('hook_completed');
    });
  });

  describe('execution order', () => {
    it('should execute hooks in priority order', async () => {
      const order: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'low-priority',
        type: 'SessionStart',
        priority: 10,
        handler: async () => {
          order.push('low');
          return { action: 'continue' };
        },
      });
      engine.register({
        name: 'high-priority',
        type: 'SessionStart',
        priority: 100,
        handler: async () => {
          order.push('high');
          return { action: 'continue' };
        },
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(order).toEqual(['high', 'low']); // High priority first
    });
  });

  describe('sessionId handling', () => {
    it('should include sessionId from context in events', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'test-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionStartContext({ sessionId: 'unique_session_id' });
      await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(events[0].sessionId).toBe('unique_session_id');
      expect(events[1].sessionId).toBe('unique_session_id');
    });
  });

  describe('PreCompact context', () => {
    it('should work with PreCompact hook type', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'compact-hook',
        type: 'PreCompact',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createPreCompactContext({
        sessionId: 'sess_123',
        currentTokens: 100000,
        targetTokens: 70000,
      });
      await engine.executeWithEvents('PreCompact', context, mockEmitter);

      expect(events).toHaveLength(2);
      const triggered = events.find(e => e.type === 'hook_triggered');
      if (triggered && triggered.type === 'hook_triggered') {
        expect(triggered.hookEvent).toBe('PreCompact');
      }
    });
  });

  describe('return type consistency', () => {
    it('should return same result type as execute()', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'test-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue', message: 'Hello' }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });

      // Both methods should return same structure
      const executeResult = await engine.execute('SessionStart', context);
      const executeWithEventsResult = await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(executeWithEventsResult.action).toBe(executeResult.action);
      expect(executeWithEventsResult.message).toBe(executeResult.message);
    });
  });
});
