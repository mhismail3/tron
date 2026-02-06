/**
 * @fileoverview Tests for memory-ledger builtin Stop hook
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createMemoryLedgerHook,
  type MemoryLedgerHookConfig,
} from '../memory-ledger.js';
import type { StopHookContext } from '../../types.js';

// =============================================================================
// Helpers
// =============================================================================

function createStopContext(overrides: Partial<StopHookContext> = {}): StopHookContext {
  return {
    hookType: 'Stop',
    sessionId: 'test-session',
    timestamp: new Date().toISOString(),
    stopReason: 'completed',
    data: {},
    ...overrides,
  };
}

function createConfig(overrides: Partial<MemoryLedgerHookConfig> = {}): MemoryLedgerHookConfig {
  return {
    onCycleComplete: vi.fn().mockResolvedValue(undefined),
    getCycleRange: vi.fn().mockReturnValue({
      firstEventId: 'evt-1',
      lastEventId: 'evt-10',
      firstTurn: 1,
      lastTurn: 3,
    }),
    getModel: vi.fn().mockReturnValue('claude-sonnet-4-5-20250929'),
    getWorkingDirectory: vi.fn().mockReturnValue('/project'),
    getTokenRatio: vi.fn().mockReturnValue(0.40),
    getRecentEventTypes: vi.fn().mockResolvedValue([]),
    getRecentToolCalls: vi.fn().mockResolvedValue([]),
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('memory-ledger hook', () => {
  describe('creation', () => {
    it('should create hook with correct properties', () => {
      const hook = createMemoryLedgerHook(createConfig());

      expect(hook.name).toBe('builtin:memory-ledger');
      expect(hook.type).toBe('Stop');
      expect(hook.mode).toBe('background');
      expect(hook.priority).toBe(10);
    });
  });

  describe('handler', () => {
    it('should call onCycleComplete on successful stop', async () => {
      const config = createConfig();
      const hook = createMemoryLedgerHook(config);
      const context = createStopContext();

      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect(config.onCycleComplete).toHaveBeenCalledWith(expect.objectContaining({
        firstEventId: 'evt-1',
        lastEventId: 'evt-10',
        firstTurn: 1,
        lastTurn: 3,
        model: 'claude-sonnet-4-5-20250929',
        workingDirectory: '/project',
        currentTokenRatio: 0.40,
      }));
    });

    it('should skip on blocked stop reason', async () => {
      const config = createConfig();
      const hook = createMemoryLedgerHook(config);
      const context = createStopContext({ stopReason: 'blocked' });

      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect(config.onCycleComplete).not.toHaveBeenCalled();
    });

    it('should handle errors gracefully (fail-open)', async () => {
      const config = createConfig({
        onCycleComplete: vi.fn().mockRejectedValue(new Error('Memory failed')),
      });
      const hook = createMemoryLedgerHook(config);
      const context = createStopContext();

      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
    });

    it('should include recent event types and tool calls', async () => {
      const config = createConfig({
        getRecentEventTypes: vi.fn().mockResolvedValue(['worktree.commit']),
        getRecentToolCalls: vi.fn().mockResolvedValue(['git push origin main']),
      });
      const hook = createMemoryLedgerHook(config);
      const context = createStopContext();

      await hook.handler(context);

      expect(config.onCycleComplete).toHaveBeenCalledWith(expect.objectContaining({
        recentEventTypes: ['worktree.commit'],
        recentToolCalls: ['git push origin main'],
      }));
    });
  });
});
