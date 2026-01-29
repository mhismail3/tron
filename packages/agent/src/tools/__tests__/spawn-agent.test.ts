/**
 * @fileoverview Tests for SpawnAgentTool
 *
 * Tests the unified spawn tool that handles both in-process and tmux modes.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { SpawnAgentTool, type SpawnAgentToolConfig, type SpawnAgentCallback } from '../subagent/spawn-agent.js';
import type { SubAgentTracker } from '../subagent/subagent-tracker.js';

describe('SpawnAgentTool', () => {
  let mockOnSpawn: SpawnAgentCallback;
  let mockTracker: SubAgentTracker;
  let config: SpawnAgentToolConfig;
  let spawnAgentTool: SpawnAgentTool;

  beforeEach(() => {
    mockOnSpawn = vi.fn().mockResolvedValue({
      sessionId: 'sub_123',
      success: true,
    });

    mockTracker = {
      register: vi.fn(),
      unregister: vi.fn(),
      markCompleted: vi.fn(),
      markFailed: vi.fn(),
      get: vi.fn(),
      list: vi.fn(),
      waitFor: vi.fn().mockResolvedValue({
        sessionId: 'sub_123',
        success: true,
        output: 'Test output',
        summary: 'Test summary',
        totalTurns: 3,
        duration: 1000,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      }),
    } as unknown as SubAgentTracker;

    config = {
      sessionId: 'parent_123',
      workingDirectory: '/test/dir',
      model: 'claude-sonnet-4-5',
      dbPath: '/test/db.sqlite',
      onSpawn: mockOnSpawn,
      getSubagentTracker: () => mockTracker,
    };

    spawnAgentTool = new SpawnAgentTool(config);
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(spawnAgentTool.name).toBe('SpawnAgent');
    });

    it('should have category custom', () => {
      expect(spawnAgentTool.category).toBe('custom');
    });

    it('should have correct label', () => {
      expect(spawnAgentTool.label).toBe('Spawn Agent');
    });

    it('should require task parameter', () => {
      expect(spawnAgentTool.parameters.required).toContain('task');
    });

    it('should have task parameter', () => {
      expect(spawnAgentTool.parameters.properties.task).toBeDefined();
      expect(spawnAgentTool.parameters.properties.task.type).toBe('string');
    });

    it('should have mode parameter', () => {
      expect(spawnAgentTool.parameters.properties.mode).toBeDefined();
      expect(spawnAgentTool.parameters.properties.mode.enum).toEqual(['inProcess', 'tmux']);
    });

    it('should have blocking parameter', () => {
      expect(spawnAgentTool.parameters.properties.blocking).toBeDefined();
      expect(spawnAgentTool.parameters.properties.blocking.type).toBe('boolean');
    });

    it('should have timeout parameter', () => {
      expect(spawnAgentTool.parameters.properties.timeout).toBeDefined();
      expect(spawnAgentTool.parameters.properties.timeout.type).toBe('number');
    });

    it('should have sessionName parameter for tmux mode', () => {
      expect(spawnAgentTool.parameters.properties.sessionName).toBeDefined();
      expect(spawnAgentTool.parameters.properties.sessionName.type).toBe('string');
    });
  });

  describe('parameter validation', () => {
    it('should reject missing task parameter', async () => {
      const result = await spawnAgentTool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter "task"');
    });

    it('should reject empty task string', async () => {
      const result = await spawnAgentTool.execute({ task: '' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter "task"');
    });

    it('should accept valid task', async () => {
      const result = await spawnAgentTool.execute({
        task: 'Test task',
        blocking: false,
      });

      expect(result.isError).toBe(false);
    });
  });

  describe('inProcess mode - blocking (default)', () => {
    it('should spawn and wait for completion by default', async () => {
      const result = await spawnAgentTool.execute({
        task: 'Test task',
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          task: 'Test task',
          mode: 'inProcess',
        }),
        expect.any(String)
      );

      expect(mockTracker.waitFor).toHaveBeenCalledWith('sub_123', 30 * 60 * 1000);
      expect(result.isError).toBe(false);
      expect(result.content).toContain('✅');
      expect(result.content).toContain('Test output');
      expect(result.details?.success).toBe(true);
    });

    it('should respect custom timeout', async () => {
      await spawnAgentTool.execute({
        task: 'Test task',
        timeout: 5000,
      });

      expect(mockTracker.waitFor).toHaveBeenCalledWith('sub_123', 5000);
    });

    it('should handle completion failure gracefully', async () => {
      (mockTracker.waitFor as ReturnType<typeof vi.fn>).mockResolvedValue({
        sessionId: 'sub_123',
        success: false,
        error: 'Task failed',
        totalTurns: 2,
        duration: 500,
        tokenUsage: { inputTokens: 50, outputTokens: 25 },
      });

      const result = await spawnAgentTool.execute({
        task: 'Test task',
      });

      expect(result.isError).toBe(false); // Not a tool error
      expect(result.content).toContain('❌');
      expect(result.content).toContain('Task failed');
    });

    it('should handle timeout error', async () => {
      (mockTracker.waitFor as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('Timeout'));

      const result = await spawnAgentTool.execute({
        task: 'Test task',
        timeout: 1000,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('timed out');
    });
  });

  describe('inProcess mode - non-blocking', () => {
    it('should return immediately when blocking=false', async () => {
      const result = await spawnAgentTool.execute({
        task: 'Test task',
        blocking: false,
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          task: 'Test task',
          mode: 'inProcess',
        }),
        expect.any(String)
      );

      expect(mockTracker.waitFor).not.toHaveBeenCalled();
      expect(result.isError).toBe(false);
      expect(result.content).toContain('spawned successfully');
      expect(result.content).toContain('QueryAgent');
    });
  });

  describe('tmux mode', () => {
    it('should spawn tmux agent with default session name', async () => {
      (mockOnSpawn as ReturnType<typeof vi.fn>).mockResolvedValue({
        sessionId: 'sub_456',
        success: true,
        tmuxSessionName: 'tron-agent-123',
      });

      const result = await spawnAgentTool.execute({
        task: 'Test task',
        mode: 'tmux',
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          task: 'Test task',
          mode: 'tmux',
        }),
        expect.any(String)
      );

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Tmux agent spawned');
      expect(result.content).toContain('tron-agent-123');
      expect(result.content).toContain('tmux attach');
    });

    it('should respect custom session name', async () => {
      (mockOnSpawn as ReturnType<typeof vi.fn>).mockResolvedValue({
        sessionId: 'sub_456',
        success: true,
        tmuxSessionName: 'my-custom-session',
      });

      const result = await spawnAgentTool.execute({
        task: 'Test task',
        mode: 'tmux',
        sessionName: 'my-custom-session',
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          sessionName: 'my-custom-session',
        }),
        expect.any(String)
      );

      expect(result.content).toContain('my-custom-session');
    });

    it('should ignore blocking parameter in tmux mode', async () => {
      (mockOnSpawn as ReturnType<typeof vi.fn>).mockResolvedValue({
        sessionId: 'sub_456',
        success: true,
        tmuxSessionName: 'tron-agent-123',
      });

      const result = await spawnAgentTool.execute({
        task: 'Test task',
        mode: 'tmux',
        blocking: true, // Should be ignored
      });

      expect(mockTracker.waitFor).not.toHaveBeenCalled();
      expect(result.isError).toBe(false);
    });
  });

  describe('spawn failure', () => {
    it('should handle spawn failure', async () => {
      (mockOnSpawn as ReturnType<typeof vi.fn>).mockResolvedValue({
        sessionId: '',
        success: false,
        error: 'Spawn failed',
      });

      const result = await spawnAgentTool.execute({
        task: 'Test task',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Failed to spawn agent');
      expect(result.content).toContain('Spawn failed');
    });

    it('should handle spawn exception', async () => {
      (mockOnSpawn as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('Connection error'));

      const result = await spawnAgentTool.execute({
        task: 'Test task',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Error spawning agent');
      expect(result.content).toContain('Connection error');
    });
  });

  describe('optional parameters', () => {
    it('should pass through all optional parameters', async () => {
      await spawnAgentTool.execute({
        task: 'Test task',
        model: 'claude-opus-4-5',
        tools: ['read', 'write'],
        skills: ['skill1'],
        workingDirectory: '/custom/dir',
        maxTurns: 25,
        blocking: false,
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          task: 'Test task',
          model: 'claude-opus-4-5',
          tools: ['read', 'write'],
          skills: ['skill1'],
          workingDirectory: '/custom/dir',
          maxTurns: 25,
          mode: 'inProcess',
        }),
        expect.any(String)
      );
    });

    it('should use config defaults when not specified', async () => {
      await spawnAgentTool.execute({
        task: 'Test task',
        blocking: false,
      });

      expect(mockOnSpawn).toHaveBeenCalledWith(
        'parent_123',
        expect.objectContaining({
          model: 'claude-sonnet-4-5',
          workingDirectory: '/test/dir',
          maxTurns: 50,
        }),
        expect.any(String)
      );
    });
  });
});
