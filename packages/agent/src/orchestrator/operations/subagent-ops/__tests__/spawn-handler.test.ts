/**
 * @fileoverview Tests for spawn-handler
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest';
import { createSpawnHandler } from '../spawn-handler.js';
import type { EventStore } from '../../../../events/event-store.js';
import type { ActiveSession } from '../../../types.js';

describe('SpawnHandler', () => {
  let updateSessionSpawnInfo: Mock;
  let getSession: Mock;
  let getAncestors: Mock;
  let getDbPath: Mock;
  let getActiveSession: Mock;
  let createSession: Mock;
  let runAgent: Mock;
  let appendEventLinearized: Mock;
  let emit: Mock;
  let spawn: Mock;
  let handler: SpawnHandler;
  let mockParentSession: ActiveSession;

  beforeEach(() => {
    spawn = vi.fn();
    const updateStatus = vi.fn();
    const complete = vi.fn();
    const fail = vi.fn();

    mockParentSession = {
      workingDirectory: '/parent/dir',
      model: 'claude-3-sonnet',
      subagentTracker: {
        spawn,
        updateStatus,
        complete,
        fail,
      },
    } as unknown as ActiveSession;

    updateSessionSpawnInfo = vi.fn();
    getSession = vi.fn();
    getAncestors = vi.fn();
    getDbPath = vi.fn().mockReturnValue('/test/db.sqlite');
    getActiveSession = vi.fn().mockReturnValue(mockParentSession);
    createSession = vi.fn().mockResolvedValue({ sessionId: 'sess_sub_123' });
    runAgent = vi.fn().mockResolvedValue(undefined);
    appendEventLinearized = vi.fn();
    emit = vi.fn();

    const mockEventStore = {
      updateSessionSpawnInfo,
      getSession,
      getAncestors,
      getDbPath,
    } as unknown as EventStore;

    handler = createSpawnHandler({
      eventStore: mockEventStore,
      getActiveSession,
      createSession,
      runAgent,
      appendEventLinearized,
      emit,
    });
  });

  describe('spawnSubsession', () => {
    it('should return error when parent session not found', async () => {
      getActiveSession.mockReturnValue(undefined);

      const result = await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Parent session not found');
      expect(result.sessionId).toBe('');
    });

    it('should create subsession with correct parameters', async () => {
      const result = await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        model: 'claude-3-opus',
        workingDirectory: '/custom/dir',
        maxTurns: 25,
      });

      expect(result.success).toBe(true);
      expect(result.sessionId).toBe('sess_sub_123');

      // Verify createSession was called with correct params
      expect(createSession).toHaveBeenCalledWith({
        workingDirectory: '/custom/dir',
        model: 'claude-3-opus',
        title: 'Subagent: Test task',
        tags: ['subagent', 'subsession'],
        parentSessionId: 'parent_123',
      });
    });

    it('should use parent defaults when not specified', async () => {
      const result = await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      });

      expect(result.success).toBe(true);

      // Verify createSession used parent defaults
      expect(createSession).toHaveBeenCalledWith(
        expect.objectContaining({
          workingDirectory: '/parent/dir',
          model: 'claude-3-sonnet',
        })
      );
    });

    it('should update session spawn info in event store', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      });

      expect(updateSessionSpawnInfo).toHaveBeenCalledWith(
        'sess_sub_123',
        'parent_123',
        'subsession',
        'Test task'
      );
    });

    it('should emit subagent.spawned event', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        model: 'claude-3-opus',
        tools: ['Bash'],
        skills: ['git'],
        maxTurns: 30,
      });

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({
          subagentSessionId: 'sess_sub_123',
          spawnType: 'subsession',
          task: 'Test task',
          model: 'claude-3-opus',
          tools: ['Bash'],
          skills: ['git'],
          maxTurns: 30,
        })
      );
    });

    it('should emit WebSocket event for iOS', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      }, 'tool_call_456');

      expect(emit).toHaveBeenCalledWith(
        'agent_event',
        expect.objectContaining({
          type: 'agent.subagent_spawned',
          sessionId: 'parent_123',
          data: expect.objectContaining({
            subagentSessionId: 'sess_sub_123',
            toolCallId: 'tool_call_456',
            task: 'Test task',
          }),
        })
      );
    });

    it('should track in parent subagent tracker', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        maxTurns: 40,
      });

      expect(spawn).toHaveBeenCalledWith(
        'sess_sub_123',
        'subsession',
        'Test task',
        'claude-3-sonnet',
        '/parent/dir',
        '',
        { maxTurns: 40 }
      );
    });

    it('should handle creation errors', async () => {
      createSession.mockRejectedValue(new Error('Creation failed'));

      const result = await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Creation failed');
    });
  });

  describe('spawnTmuxAgent', () => {
    it('should return error when parent session not found', async () => {
      getActiveSession.mockReturnValue(undefined);

      const result = await handler.spawnTmuxAgent('parent_123', {
        task: 'Test task',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Parent session not found');
      expect(result.sessionId).toBe('');
      expect(result.tmuxSessionName).toBe('');
    });

    it('should use custom session name when provided', async () => {
      const result = await handler.spawnTmuxAgent('parent_123', {
        task: 'Test task',
        sessionName: 'custom-session',
      });

      expect(result.success).toBe(true);
      expect(result.tmuxSessionName).toBe('custom-session');
    });

    it('should emit subagent.spawned event for tmux', async () => {
      await handler.spawnTmuxAgent('parent_123', {
        task: 'Test task',
        model: 'claude-3-opus',
        maxTurns: 50,
      });

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({
          spawnType: 'tmux',
          task: 'Test task',
          model: 'claude-3-opus',
          maxTurns: 50,
        })
      );
    });

    it('should track in parent subagent tracker with tmux info', async () => {
      const result = await handler.spawnTmuxAgent('parent_123', {
        task: 'Test task',
        sessionName: 'test-session',
        maxTurns: 75,
      });

      expect(spawn).toHaveBeenCalledWith(
        result.sessionId,
        'tmux',
        'Test task',
        'claude-3-sonnet',
        '/parent/dir',
        '',
        { tmuxSessionName: 'test-session', maxTurns: 75 }
      );
    });
  });
});
