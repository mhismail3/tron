/**
 * @fileoverview Tests for background hook execution mode
 *
 * TDD: These tests were written first, before implementing the feature.
 * Background hooks run fire-and-forget - the agent continues immediately
 * without waiting for them to complete.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { HookEngine } from '../engine.js';
import type { TronEvent } from '../../types/index.js';
import type { HookDefinition } from '../types.js';
import {
  createSessionStartContext,
  createSessionEndContext,
  createPreToolUseContext,
  createUserPromptSubmitContext,
  createPreCompactContext,
  createPostToolUseContext,
  createNotificationContext,
} from './context-factories.js';

describe('background hook execution', () => {
  let engine: HookEngine;

  beforeEach(() => {
    engine = new HookEngine();
  });

  afterEach(() => {
    engine.clear();
  });

  // ===========================================================================
  // Registration Tests
  // ===========================================================================

  describe('registration', () => {
    it('should accept mode property in HookDefinition', () => {
      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks).toHaveLength(1);
      expect(hooks[0].mode).toBe('background');
    });

    it('should default to blocking mode when not specified', () => {
      engine.register({
        name: 'default-hook',
        type: 'SessionEnd',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should force blocking mode for PreToolUse hooks', () => {
      engine.register({
        name: 'tool-hook',
        type: 'PreToolUse',
        mode: 'background', // This should be overridden
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should force blocking mode for UserPromptSubmit hooks', () => {
      engine.register({
        name: 'prompt-hook',
        type: 'UserPromptSubmit',
        mode: 'background', // This should be overridden
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should force blocking mode for PreCompact hooks', () => {
      engine.register({
        name: 'compact-hook',
        type: 'PreCompact',
        mode: 'background', // This should be overridden
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('blocking');
    });

    it('should allow background mode for SessionEnd hooks', () => {
      engine.register({
        name: 'session-end-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('background');
    });

    it('should allow background mode for PostToolUse hooks', () => {
      engine.register({
        name: 'post-tool-hook',
        type: 'PostToolUse',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('background');
    });

    it('should allow background mode for Stop hooks', () => {
      engine.register({
        name: 'stop-hook',
        type: 'Stop',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('background');
    });

    it('should allow background mode for Notification hooks', () => {
      engine.register({
        name: 'notification-hook',
        type: 'Notification',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const hooks = engine.listHooks();
      expect(hooks[0].mode).toBe('background');
    });
  });

  // ===========================================================================
  // Execution Behavior Tests
  // ===========================================================================

  describe('execution behavior', () => {
    it('should not wait for background hooks to complete', async () => {
      const executionOrder: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'slow-background',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 100));
          executionOrder.push('background-done');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      const startTime = Date.now();
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      const duration = Date.now() - startTime;

      executionOrder.push('executeWithEvents-returned');

      // executeWithEvents should return almost immediately (< 50ms)
      // without waiting for the 100ms background hook
      expect(duration).toBeLessThan(50);
      expect(executionOrder).toEqual(['executeWithEvents-returned']);

      // Wait for background to finish for cleanup
      await engine.waitForBackgroundHooks();
      expect(executionOrder).toContain('background-done');
    });

    it('should execute blocking hooks before starting background hooks', async () => {
      const executionOrder: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'blocking-hook',
        type: 'SessionEnd',
        mode: 'blocking',
        handler: async () => {
          executionOrder.push('blocking');
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'background-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          executionOrder.push('background');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      // Blocking should execute first, then background starts
      expect(executionOrder.indexOf('blocking')).toBeLessThan(executionOrder.indexOf('background'));
    });

    it('should continue to next operation while background hooks run', async () => {
      const mockEmitter = { emit: vi.fn() };
      let backgroundStarted = false;
      let backgroundComplete = false;

      engine.register({
        name: 'slow-background',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          backgroundStarted = true;
          await new Promise(r => setTimeout(r, 100));
          backgroundComplete = true;
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      // Background hook should have started but not completed
      // (it may or may not have started yet due to microtask timing)
      expect(backgroundComplete).toBe(false);

      await engine.waitForBackgroundHooks();
      expect(backgroundComplete).toBe(true);
    });

    it('should return blocking hook result regardless of background hooks', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'modifier-blocking',
        type: 'SessionEnd',
        mode: 'blocking',
        handler: async () => ({
          action: 'modify',
          modifications: { outcome: 'success' },
        }),
      });

      engine.register({
        name: 'background-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 50));
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      const result = await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      expect(result.action).toBe('modify');
      expect(result.modifications?.outcome).toBe('success');

      await engine.waitForBackgroundHooks();
    });
  });

  // ===========================================================================
  // Event Emission Tests
  // ===========================================================================

  describe('event emission', () => {
    it('should emit hook.background_started when background hooks begin', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgStarted = events.find(e => e.type === 'hook.background_started');
      expect(bgStarted).toBeDefined();
    });

    it('should emit hook.background_completed when background hooks finish', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgCompleted = events.find(e => e.type === 'hook.background_completed');
      expect(bgCompleted).toBeDefined();
    });

    it('should include executionId for correlation in events', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgStarted = events.find(e => e.type === 'hook.background_started') as any;
      const bgCompleted = events.find(e => e.type === 'hook.background_completed') as any;

      expect(bgStarted?.executionId).toBeDefined();
      expect(bgCompleted?.executionId).toBeDefined();
      expect(bgStarted?.executionId).toBe(bgCompleted?.executionId);
    });

    it('should include hookNames in background events', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'bg-hook-a',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      engine.register({
        name: 'bg-hook-b',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgStarted = events.find(e => e.type === 'hook.background_started') as any;
      expect(bgStarted?.hookNames).toContain('bg-hook-a');
      expect(bgStarted?.hookNames).toContain('bg-hook-b');
    });

    it('should include duration in hook.background_completed event', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'slow-bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 50));
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgCompleted = events.find(e => e.type === 'hook.background_completed') as any;
      // Allow slight timing variance (timer resolution can vary by a few ms)
      expect(bgCompleted?.duration).toBeGreaterThanOrEqual(45);
    });

    it('should still emit blocking hook events separately', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'blocking-hook',
        type: 'SessionEnd',
        mode: 'blocking',
        handler: async () => ({ action: 'continue' }),
      });

      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      // Should have both blocking events and background events
      const hookTriggered = events.find(e => e.type === 'hook_triggered');
      const hookCompleted = events.find(e => e.type === 'hook_completed');
      const bgStarted = events.find(e => e.type === 'hook.background_started');
      const bgCompleted = events.find(e => e.type === 'hook.background_completed');

      expect(hookTriggered).toBeDefined();
      expect(hookCompleted).toBeDefined();
      expect(bgStarted).toBeDefined();
      expect(bgCompleted).toBeDefined();
    });
  });

  // ===========================================================================
  // Error Handling Tests
  // ===========================================================================

  describe('error handling', () => {
    it('should not throw when background hook errors (fail-open)', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'error-bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          throw new Error('Background hook crashed');
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });

      // Should not throw
      await expect(
        engine.executeWithEvents('SessionEnd', context, mockEmitter)
      ).resolves.not.toThrow();

      // Should complete without error
      await expect(engine.waitForBackgroundHooks()).resolves.not.toThrow();
    });

    it('should log errors from background hooks', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'error-bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          throw new Error('Background hook crashed');
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      const bgCompleted = events.find(e => e.type === 'hook.background_completed') as any;
      expect(bgCompleted).toBeDefined();
      expect(bgCompleted?.result).toBe('error');
      expect(bgCompleted?.error).toContain('Background hook crashed');
    });

    it('should continue executing other background hooks after error', async () => {
      const executed: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'error-hook',
        type: 'SessionEnd',
        mode: 'background',
        priority: 100, // Higher priority, runs first
        handler: async () => {
          executed.push('error-hook');
          throw new Error('First hook crashed');
        },
      });

      engine.register({
        name: 'success-hook',
        type: 'SessionEnd',
        mode: 'background',
        priority: 0, // Lower priority
        handler: async () => {
          executed.push('success-hook');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      // Both hooks should have executed
      expect(executed).toContain('error-hook');
      expect(executed).toContain('success-hook');
    });
  });

  // ===========================================================================
  // Timeout Tests
  // ===========================================================================

  describe('timeout handling', () => {
    it('should respect timeout for background hooks', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'slow-bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        timeout: 50, // 50ms timeout
        handler: async () => {
          await new Promise(r => setTimeout(r, 200)); // Takes 200ms
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks(500); // Wait up to 500ms

      const bgCompleted = events.find(e => e.type === 'hook.background_completed') as any;
      expect(bgCompleted).toBeDefined();
      // Should have errored due to timeout
      expect(bgCompleted?.result).toBe('error');
      expect(bgCompleted?.error).toMatch(/timed out/i);
    });
  });

  // ===========================================================================
  // Drain Tests
  // ===========================================================================

  describe('drain functionality', () => {
    it('should provide waitForBackgroundHooks method', () => {
      expect(typeof engine.waitForBackgroundHooks).toBe('function');
    });

    it('should wait for all pending background hooks to complete', async () => {
      const completed: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'bg-hook-1',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 30));
          completed.push('hook-1');
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'bg-hook-2',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 60));
          completed.push('hook-2');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      // Neither should be complete yet
      expect(completed).toHaveLength(0);

      await engine.waitForBackgroundHooks();

      // Both should be complete
      expect(completed).toContain('hook-1');
      expect(completed).toContain('hook-2');
    });

    it('should timeout if background hooks take too long to drain', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'very-slow-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 5000)); // 5 seconds
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      const startTime = Date.now();
      await engine.waitForBackgroundHooks(100); // Only wait 100ms
      const elapsed = Date.now() - startTime;

      // Should have timed out around 100ms, not waited 5 seconds
      expect(elapsed).toBeLessThan(200);
      expect(elapsed).toBeGreaterThanOrEqual(100);
    });

    it('should return immediately if no background hooks pending', async () => {
      const startTime = Date.now();
      await engine.waitForBackgroundHooks();
      const elapsed = Date.now() - startTime;

      // Should be nearly instant
      expect(elapsed).toBeLessThan(10);
    });

    it('should provide getPendingBackgroundCount method', () => {
      expect(typeof engine.getPendingBackgroundCount).toBe('function');
    });

    it('should track pending background hook count', async () => {
      const mockEmitter = { emit: vi.fn() };

      expect(engine.getPendingBackgroundCount()).toBe(0);

      engine.register({
        name: 'bg-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 100));
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      // Should have 1 pending
      expect(engine.getPendingBackgroundCount()).toBe(1);

      await engine.waitForBackgroundHooks();

      // Should be 0 after completion
      expect(engine.getPendingBackgroundCount()).toBe(0);
    });
  });

  // ===========================================================================
  // Mixed Mode Tests
  // ===========================================================================

  describe('mixed blocking and background hooks', () => {
    it('should execute both blocking and background hooks for same type', async () => {
      const executed: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'blocking-hook',
        type: 'SessionEnd',
        mode: 'blocking',
        handler: async () => {
          executed.push('blocking');
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'background-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          executed.push('background');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);
      await engine.waitForBackgroundHooks();

      expect(executed).toContain('blocking');
      expect(executed).toContain('background');
    });

    it('should respect priority within blocking hooks only', async () => {
      const order: string[] = [];
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'low-priority-blocking',
        type: 'SessionEnd',
        mode: 'blocking',
        priority: 10,
        handler: async () => {
          order.push('low-blocking');
          return { action: 'continue' };
        },
      });

      engine.register({
        name: 'high-priority-blocking',
        type: 'SessionEnd',
        mode: 'blocking',
        priority: 100,
        handler: async () => {
          order.push('high-blocking');
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      // High priority should run before low priority
      expect(order.indexOf('high-blocking')).toBeLessThan(order.indexOf('low-blocking'));
    });

    it('should handle block result from blocking hook while background runs', async () => {
      let backgroundComplete = false;
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'blocker',
        type: 'SessionEnd',
        mode: 'blocking',
        handler: async () => ({ action: 'block', reason: 'Blocked!' }),
      });

      engine.register({
        name: 'background-hook',
        type: 'SessionEnd',
        mode: 'background',
        handler: async () => {
          await new Promise(r => setTimeout(r, 50));
          backgroundComplete = true;
          return { action: 'continue' };
        },
      });

      const context = createSessionEndContext({ sessionId: 'sess_123' });
      const result = await engine.executeWithEvents('SessionEnd', context, mockEmitter);

      // Should get block result from blocking hook
      expect(result.action).toBe('block');
      expect(result.reason).toBe('Blocked!');

      // Background hook should still run
      await engine.waitForBackgroundHooks();
      expect(backgroundComplete).toBe(true);
    });
  });

  // ===========================================================================
  // Backward Compatibility Tests
  // ===========================================================================

  describe('backward compatibility', () => {
    it('should maintain existing behavior for hooks without mode', async () => {
      const mockEmitter = { emit: vi.fn() };

      engine.register({
        name: 'legacy-hook',
        type: 'SessionStart',
        handler: async () => ({ action: 'continue' }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      const result = await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(result.action).toBe('continue');
      // No background hooks should be pending
      expect(engine.getPendingBackgroundCount()).toBe(0);
    });

    it('should work identically to before for all blocking hooks', async () => {
      const events: TronEvent[] = [];
      const mockEmitter = { emit: (e: TronEvent) => events.push(e) };

      engine.register({
        name: 'blocking-hook',
        type: 'SessionStart',
        mode: 'blocking',
        handler: async () => ({
          action: 'modify',
          modifications: { foo: 'bar' },
        }),
      });

      const context = createSessionStartContext({ sessionId: 'sess_123' });
      const result = await engine.executeWithEvents('SessionStart', context, mockEmitter);

      expect(result.action).toBe('modify');
      expect(result.modifications?.foo).toBe('bar');

      // Should have normal hook events
      expect(events.some(e => e.type === 'hook_triggered')).toBe(true);
      expect(events.some(e => e.type === 'hook_completed')).toBe(true);
    });
  });
});
