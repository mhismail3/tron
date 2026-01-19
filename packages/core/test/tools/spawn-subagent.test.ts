/**
 * @fileoverview Tests for SpawnSubagent tool
 *
 * TDD tests for blocking subagent spawning behavior:
 * - Default blocking mode: waits for subagent completion
 * - Returns full result when blocking
 * - Timeout handling
 * - Non-blocking mode (future extensibility)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { SpawnSubagentTool } from '../../src/tools/spawn-subagent.js';
import { SubAgentTracker } from '../../src/subagents/subagent-tracker.js';
import type { SpawnSubagentToolConfig, SpawnSubagentParams } from '../../src/tools/spawn-subagent.js';
import type { SessionId } from '../../src/events/types.js';

describe('SpawnSubagentTool', () => {
  let tool: SpawnSubagentTool;
  let mockOnSpawn: ReturnType<typeof vi.fn>;
  let mockTracker: SubAgentTracker;

  beforeEach(() => {
    mockOnSpawn = vi.fn();
    mockTracker = new SubAgentTracker();

    const config: SpawnSubagentToolConfig = {
      sessionId: 'parent-session-123',
      workingDirectory: '/test/project',
      model: 'claude-3-sonnet',
      onSpawn: mockOnSpawn,
      getSubagentTracker: () => mockTracker,
    };

    tool = new SpawnSubagentTool(config);
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('SpawnSubagent');
    });

    it('should have description mentioning blocking behavior', () => {
      expect(tool.description).toContain('blocks');
    });

    it('should define required task parameter', () => {
      expect(tool.parameters.properties).toHaveProperty('task');
      expect(tool.parameters.required).toContain('task');
    });

    it('should define optional blocking parameter', () => {
      expect(tool.parameters.properties).toHaveProperty('blocking');
    });

    it('should define optional timeout parameter', () => {
      expect(tool.parameters.properties).toHaveProperty('timeout');
    });
  });

  describe('blocking mode (default)', () => {
    it('should block until subagent completes', async () => {
      const subagentSessionId = 'sub-session-abc';

      // Mock spawn to create the subagent
      mockOnSpawn.mockImplementation(async () => {
        // Simulate spawning - add to tracker
        mockTracker.spawn(
          subagentSessionId as SessionId,
          'subsession',
          'Test task',
          'claude-3-sonnet',
          '/test',
          'event-1'
        );
        mockTracker.updateStatus(subagentSessionId as SessionId, 'running');
        return { sessionId: subagentSessionId, success: true };
      });

      // Start execution (should block)
      const executePromise = tool.execute('tool-call-1', { task: 'Test task' });

      // Give it a moment to start blocking
      await new Promise(resolve => setTimeout(resolve, 10));

      // Complete the subagent
      mockTracker.complete(
        subagentSessionId as SessionId,
        'Task completed successfully',
        3,
        { inputTokens: 1000, outputTokens: 500 },
        5000,
        'Full output from subagent'
      );

      // Now execution should resolve
      const result = await executePromise;

      expect(result.isError).toBeFalsy();
      expect(result.details).toHaveProperty('sessionId', subagentSessionId);
      expect(result.details).toHaveProperty('success', true);
      expect(result.details).toHaveProperty('output', 'Full output from subagent');
      expect(result.details).toHaveProperty('totalTurns', 3);
      expect(result.details).toHaveProperty('duration', 5000);
    });

    it('should return full result on completion', async () => {
      const subagentSessionId = 'sub-session-def';

      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(
          subagentSessionId as SessionId,
          'subsession',
          'Complex task',
          'claude-3-opus',
          '/test',
          'event-2'
        );
        mockTracker.updateStatus(subagentSessionId as SessionId, 'running');

        // Immediately complete
        setTimeout(() => {
          mockTracker.complete(
            subagentSessionId as SessionId,
            'Complex task done',
            10,
            { inputTokens: 5000, outputTokens: 2000 },
            15000,
            'Detailed output with results'
          );
        }, 5);

        return { sessionId: subagentSessionId, success: true };
      });

      const result = await tool.execute('tool-call-2', { task: 'Complex task' });

      expect(result.isError).toBeFalsy();
      expect(result.details?.output).toBe('Detailed output with results');
      expect(result.details?.summary).toBe('Complex task done');
      expect(result.details?.totalTurns).toBe(10);
      expect(result.details?.tokenUsage).toEqual({ inputTokens: 5000, outputTokens: 2000 });
    });

    it('should handle subagent failure', async () => {
      const subagentSessionId = 'sub-session-fail';

      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(
          subagentSessionId as SessionId,
          'subsession',
          'Failing task',
          'claude-3-sonnet',
          '/test',
          'event-3'
        );
        mockTracker.updateStatus(subagentSessionId as SessionId, 'running');

        // Fail the subagent
        setTimeout(() => {
          mockTracker.fail(subagentSessionId as SessionId, 'Out of memory', { duration: 3000 });
        }, 5);

        return { sessionId: subagentSessionId, success: true };
      });

      const result = await tool.execute('tool-call-3', { task: 'Failing task' });

      expect(result.details?.success).toBe(false);
      expect(result.details?.error).toBe('Out of memory');
    });

    it('should timeout after specified duration', async () => {
      const subagentSessionId = 'sub-session-timeout';

      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(
          subagentSessionId as SessionId,
          'subsession',
          'Long task',
          'claude-3-sonnet',
          '/test',
          'event-4'
        );
        mockTracker.updateStatus(subagentSessionId as SessionId, 'running');
        // Don't complete - let it timeout
        return { sessionId: subagentSessionId, success: true };
      });

      const result = await tool.execute('tool-call-4', {
        task: 'Long task',
        timeout: 50, // 50ms timeout for testing
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('timed out');
      expect(result.details?.success).toBe(false);
    });

    it('should use default 30 minute timeout', async () => {
      const subagentSessionId = 'sub-session-default-timeout';

      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(
          subagentSessionId as SessionId,
          'subsession',
          'Task',
          'claude-3-sonnet',
          '/test',
          'event-5'
        );
        mockTracker.updateStatus(subagentSessionId as SessionId, 'running');

        // Complete immediately to not actually wait 30 min
        setTimeout(() => {
          mockTracker.complete(
            subagentSessionId as SessionId,
            'Done',
            1,
            { inputTokens: 100, outputTokens: 50 },
            100
          );
        }, 5);

        return { sessionId: subagentSessionId, success: true };
      });

      // Execute without timeout param - should use default
      const result = await tool.execute('tool-call-5', { task: 'Task' });

      expect(result.isError).toBeFalsy();
      expect(result.details?.success).toBe(true);
    });
  });

  describe('non-blocking mode (future)', () => {
    it('should return immediately when blocking=false', async () => {
      const subagentSessionId = 'sub-session-nonblock';

      mockOnSpawn.mockResolvedValue({
        sessionId: subagentSessionId,
        success: true,
      });

      const result = await tool.execute('tool-call-6', {
        task: 'Non-blocking task',
        blocking: false,
      });

      expect(result.isError).toBeFalsy();
      expect(result.details?.sessionId).toBe(subagentSessionId);
      expect(result.details?.success).toBe(true);
      // Should NOT have output/turns since it returned immediately
      expect(result.details?.output).toBeUndefined();
      expect(result.details?.totalTurns).toBeUndefined();
      expect(result.content).toContain('QuerySubagent');
    });
  });

  describe('spawn failure', () => {
    it('should return error if spawn fails', async () => {
      mockOnSpawn.mockResolvedValue({
        sessionId: '',
        success: false,
        error: 'Parent session not found',
      });

      const result = await tool.execute('tool-call-7', { task: 'Failed spawn' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Failed to spawn');
      expect(result.content).toContain('Parent session not found');
    });

    it('should handle spawn exception', async () => {
      mockOnSpawn.mockRejectedValue(new Error('Connection refused'));

      const result = await tool.execute('tool-call-8', { task: 'Exception spawn' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Error spawning sub-agent');
      expect(result.content).toContain('Connection refused');
    });
  });

  describe('parameter validation', () => {
    it('should require task parameter', async () => {
      const result = await tool.execute('tool-call-9', {});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should accept optional model parameter', async () => {
      mockOnSpawn.mockImplementation(async (parentId, params) => {
        expect(params.model).toBe('claude-3-opus');

        const subId = 'sub-model-test';
        mockTracker.spawn(subId as SessionId, 'subsession', params.task, params.model!, '/test', 'e1');
        mockTracker.updateStatus(subId as SessionId, 'running');
        setTimeout(() => mockTracker.complete(subId as SessionId, 'Done', 1, { inputTokens: 1, outputTokens: 1 }, 1), 5);
        return { sessionId: subId, success: true };
      });

      await tool.execute('tool-call-10', { task: 'Model test', model: 'claude-3-opus' });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent-session-123',
        expect.objectContaining({ model: 'claude-3-opus' }),
        expect.any(String)  // toolCallId
      );
    });

    it('should accept optional maxTurns parameter', async () => {
      mockOnSpawn.mockImplementation(async (parentId, params) => {
        expect(params.maxTurns).toBe(100);

        const subId = 'sub-turns-test';
        mockTracker.spawn(subId as SessionId, 'subsession', params.task, 'model', '/test', 'e1');
        mockTracker.updateStatus(subId as SessionId, 'running');
        setTimeout(() => mockTracker.complete(subId as SessionId, 'Done', 1, { inputTokens: 1, outputTokens: 1 }, 1), 5);
        return { sessionId: subId, success: true };
      });

      await tool.execute('tool-call-11', { task: 'Turns test', maxTurns: 100 });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent-session-123',
        expect.objectContaining({ maxTurns: 100 }),
        expect.any(String)  // toolCallId
      );
    });
  });

  describe('result content formatting', () => {
    it('should include session ID in blocking result', async () => {
      const subId = 'sub-format-1';
      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(subId as SessionId, 'subsession', 'Task', 'model', '/test', 'e1');
        mockTracker.updateStatus(subId as SessionId, 'running');
        setTimeout(() => mockTracker.complete(subId as SessionId, 'Done', 1, { inputTokens: 1, outputTokens: 1 }, 1000), 5);
        return { sessionId: subId, success: true };
      });

      const result = await tool.execute('tc', { task: 'Task' });

      expect(result.content).toContain(subId);
    });

    it('should include duration in human-readable format', async () => {
      const subId = 'sub-format-2';
      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(subId as SessionId, 'subsession', 'Task', 'model', '/test', 'e1');
        mockTracker.updateStatus(subId as SessionId, 'running');
        setTimeout(() => mockTracker.complete(subId as SessionId, 'Done', 5, { inputTokens: 100, outputTokens: 50 }, 12345), 5);
        return { sessionId: subId, success: true };
      });

      const result = await tool.execute('tc', { task: 'Task' });

      // Should format duration nicely (12.3s or similar)
      expect(result.content).toMatch(/12\.\d+s|12345ms/);
    });

    it('should include turn count', async () => {
      const subId = 'sub-format-3';
      mockOnSpawn.mockImplementation(async () => {
        mockTracker.spawn(subId as SessionId, 'subsession', 'Task', 'model', '/test', 'e1');
        mockTracker.updateStatus(subId as SessionId, 'running');
        setTimeout(() => mockTracker.complete(subId as SessionId, 'Done', 7, { inputTokens: 100, outputTokens: 50 }, 1000), 5);
        return { sessionId: subId, success: true };
      });

      const result = await tool.execute('tc', { task: 'Task' });

      expect(result.content).toContain('7');
    });
  });
});

describe('SubAgentTracker blocking integration', () => {
  let tracker: SubAgentTracker;

  beforeEach(() => {
    tracker = new SubAgentTracker();
  });

  describe('waitFor', () => {
    it('should resolve immediately if already completed', async () => {
      const sessionId = 'already-done' as SessionId;

      tracker.spawn(sessionId, 'subsession', 'Task', 'model', '/dir', 'e1');
      tracker.updateStatus(sessionId, 'running');
      tracker.complete(sessionId, 'Done', 5, { inputTokens: 100, outputTokens: 50 }, 2000, 'Full output');

      const result = await tracker.waitFor(sessionId, 5000);

      expect(result.success).toBe(true);
      expect(result.output).toBe('Full output');
      expect(result.totalTurns).toBe(5);
    });

    it('should resolve immediately if already failed', async () => {
      const sessionId = 'already-failed' as SessionId;

      tracker.spawn(sessionId, 'subsession', 'Task', 'model', '/dir', 'e1');
      tracker.updateStatus(sessionId, 'running');
      tracker.fail(sessionId, 'Some error', { duration: 1000 });

      const result = await tracker.waitFor(sessionId, 5000);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Some error');
    });

    it('should wait for completion', async () => {
      const sessionId = 'will-complete' as SessionId;

      tracker.spawn(sessionId, 'subsession', 'Task', 'model', '/dir', 'e1');
      tracker.updateStatus(sessionId, 'running');

      // Complete after delay
      setTimeout(() => {
        tracker.complete(sessionId, 'Done', 3, { inputTokens: 50, outputTokens: 25 }, 1500, 'Output');
      }, 20);

      const result = await tracker.waitFor(sessionId, 5000);

      expect(result.success).toBe(true);
      expect(result.output).toBe('Output');
    });

    it('should timeout if not completed in time', async () => {
      const sessionId = 'slow-session' as SessionId;

      tracker.spawn(sessionId, 'subsession', 'Task', 'model', '/dir', 'e1');
      tracker.updateStatus(sessionId, 'running');
      // Never complete

      await expect(tracker.waitFor(sessionId, 50)).rejects.toThrow('Timeout');
    });

    it('should reject if session not found', async () => {
      await expect(tracker.waitFor('nonexistent' as SessionId, 100)).rejects.toThrow('not found');
    });
  });

  describe('waitForAll', () => {
    it('should wait for all sessions', async () => {
      const id1 = 'session-1' as SessionId;
      const id2 = 'session-2' as SessionId;

      tracker.spawn(id1, 'subsession', 'Task 1', 'model', '/dir', 'e1');
      tracker.spawn(id2, 'subsession', 'Task 2', 'model', '/dir', 'e2');
      tracker.updateStatus(id1, 'running');
      tracker.updateStatus(id2, 'running');

      setTimeout(() => tracker.complete(id1, 'Done 1', 1, { inputTokens: 10, outputTokens: 5 }, 100, 'Out 1'), 10);
      setTimeout(() => tracker.complete(id2, 'Done 2', 2, { inputTokens: 20, outputTokens: 10 }, 200, 'Out 2'), 30);

      const results = await tracker.waitForAll([id1, id2], 5000);

      expect(results).toHaveLength(2);
      expect(results[0].output).toBe('Out 1');
      expect(results[1].output).toBe('Out 2');
    });
  });

  describe('waitForAny', () => {
    it('should return when first session completes', async () => {
      const id1 = 'fast-session' as SessionId;
      const id2 = 'slow-session' as SessionId;

      tracker.spawn(id1, 'subsession', 'Fast', 'model', '/dir', 'e1');
      tracker.spawn(id2, 'subsession', 'Slow', 'model', '/dir', 'e2');
      tracker.updateStatus(id1, 'running');
      tracker.updateStatus(id2, 'running');

      setTimeout(() => tracker.complete(id1, 'Fast done', 1, { inputTokens: 5, outputTokens: 2 }, 50, 'Fast out'), 10);
      // id2 never completes

      const result = await tracker.waitForAny([id1, id2], 5000);

      expect(result.sessionId).toBe(id1);
      expect(result.output).toBe('Fast out');
    });
  });
});
