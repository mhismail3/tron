/**
 * @fileoverview Tests for SpawnSubagent Tool
 *
 * Tests abort signal handling for blocking subagent mode.
 * When a parent session is interrupted, blocking subagent waits should abort
 * gracefully and return an interrupted result.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SpawnSubagentTool } from '../spawn-subagent.js';
import type { SpawnSubagentCallback, SpawnSubagentResult } from '../spawn-subagent.js';
import type { SubAgentTracker, SubagentResult } from '../subagent-tracker.js';
import type { SessionId } from '@infrastructure/events/types.js';

describe('SpawnSubagentTool', () => {
  describe('abort handling', () => {
    it('should return interrupted result when abort signal fires during blocking wait', async () => {
      // Setup abort controller
      const abortController = new AbortController();

      // Mock tracker that delays indefinitely (simulating long-running subagent)
      const mockTracker = {
        waitFor: vi.fn((_sessionId: SessionId, _timeout: number) => {
          return new Promise<SubagentResult>((resolve) => {
            // This promise will never resolve naturally - it will be aborted
            setTimeout(() => {
              resolve({
                sessionId: 'sess_test' as SessionId,
                success: true,
                output: 'This should not be returned',
                summary: 'Should not see this',
                task: 'Test task',
                totalTurns: 1,
                tokenUsage: { inputTokens: 100, outputTokens: 50 },
                duration: 1000,
                completedAt: new Date().toISOString(),
              });
            }, 60000); // Long delay
          });
        }),
      } as unknown as SubAgentTracker;

      // Mock spawn callback that succeeds
      const onSpawn: SpawnSubagentCallback = vi.fn(async () => ({
        sessionId: 'sess_subagent_123',
        success: true,
      }));

      const tool = new SpawnSubagentTool({
        sessionId: 'sess_parent',
        workingDirectory: '/test',
        model: 'claude-3-5-sonnet',
        dbPath: '/test/db.sqlite',
        onSpawn,
        getSubagentTracker: () => mockTracker,
      });

      // Start execution (don't await yet)
      const executePromise = tool.execute(
        'tool_call_123',
        { task: 'Test task', blocking: true },
        abortController.signal
      );

      // Give it a moment to start waiting
      await new Promise(resolve => setTimeout(resolve, 10));

      // Fire the abort signal
      abortController.abort();

      // Now await the result
      const result = await executePromise;

      // Should return interrupted result, not error
      expect(result.isError).toBe(false);
      expect(result.content).toContain('interrupted');
      expect(result.details).toHaveProperty('interrupted', true);
      expect(result.details).toHaveProperty('sessionId', 'sess_subagent_123');
    });

    it('should return interrupted result immediately if signal is already aborted', async () => {
      // Setup already-aborted controller
      const abortController = new AbortController();
      abortController.abort();

      const mockTracker = {
        waitFor: vi.fn(() => Promise.resolve({
          sessionId: 'sess_test' as SessionId,
          success: true,
          output: 'Should not be returned',
          summary: 'Should not see this',
          task: 'Test task',
          totalTurns: 1,
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          duration: 1000,
          completedAt: new Date().toISOString(),
        })),
      } as unknown as SubAgentTracker;

      const onSpawn: SpawnSubagentCallback = vi.fn(async () => ({
        sessionId: 'sess_subagent_456',
        success: true,
      }));

      const tool = new SpawnSubagentTool({
        sessionId: 'sess_parent',
        workingDirectory: '/test',
        model: 'claude-3-5-sonnet',
        dbPath: '/test/db.sqlite',
        onSpawn,
        getSubagentTracker: () => mockTracker,
      });

      const result = await tool.execute(
        'tool_call_456',
        { task: 'Test task', blocking: true },
        abortController.signal
      );

      // Should return interrupted result
      expect(result.isError).toBe(false);
      expect(result.content).toContain('interrupted');
      expect(result.details).toHaveProperty('interrupted', true);
    });

    it('should NOT abort non-blocking subagent when parent aborts', async () => {
      const abortController = new AbortController();

      const mockTracker = {
        waitFor: vi.fn(),
      } as unknown as SubAgentTracker;

      const onSpawn: SpawnSubagentCallback = vi.fn(async () => ({
        sessionId: 'sess_subagent_nonblock',
        success: true,
      }));

      const tool = new SpawnSubagentTool({
        sessionId: 'sess_parent',
        workingDirectory: '/test',
        model: 'claude-3-5-sonnet',
        dbPath: '/test/db.sqlite',
        onSpawn,
        getSubagentTracker: () => mockTracker,
      });

      // Execute with blocking: false
      const result = await tool.execute(
        'tool_call_789',
        { task: 'Non-blocking task', blocking: false },
        abortController.signal
      );

      // Non-blocking should return immediately with success
      expect(result.isError).toBe(false);
      expect(result.content).toContain('spawned successfully');
      expect(result.content).not.toContain('interrupted');

      // waitFor should NOT have been called for non-blocking mode
      expect(mockTracker.waitFor).not.toHaveBeenCalled();

      // Abort shouldn't affect the non-blocking result
      abortController.abort();

      // The subagent session should still be running (we just returned immediately)
      expect(result.details?.sessionId).toBe('sess_subagent_nonblock');
    });

    it('should complete normally if no abort signal during blocking wait', async () => {
      const mockTracker = {
        waitFor: vi.fn(async () => ({
          sessionId: 'sess_test' as SessionId,
          success: true,
          output: 'Task completed successfully',
          summary: 'Done',
          task: 'Test task',
          totalTurns: 3,
          tokenUsage: { inputTokens: 500, outputTokens: 200 },
          duration: 5000,
          completedAt: new Date().toISOString(),
        })),
      } as unknown as SubAgentTracker;

      const onSpawn: SpawnSubagentCallback = vi.fn(async () => ({
        sessionId: 'sess_subagent_normal',
        success: true,
      }));

      const tool = new SpawnSubagentTool({
        sessionId: 'sess_parent',
        workingDirectory: '/test',
        model: 'claude-3-5-sonnet',
        dbPath: '/test/db.sqlite',
        onSpawn,
        getSubagentTracker: () => mockTracker,
      });

      // Execute without abort signal
      const result = await tool.execute(
        'tool_call_normal',
        { task: 'Normal task', blocking: true }
      );

      // Should complete normally
      expect(result.isError).toBe(false);
      expect(result.content).toContain('completed successfully');
      expect(result.content).not.toContain('interrupted');
      expect(result.details?.success).toBe(true);
      expect(result.details?.totalTurns).toBe(3);
    });
  });
});
