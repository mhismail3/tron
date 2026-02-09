/**
 * @fileoverview Tests for spawn-handler
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest';
import { EventEmitter } from 'events';
import { PassThrough } from 'stream';
import { createSpawnHandler, type SpawnHandler } from '../spawn-handler.js';
import type { EventStore } from '../../../../events/event-store.js';
import type { ActiveSession } from '../../../types.js';

vi.mock('child_process', () => ({
  spawn: vi.fn(),
}));

import { spawn as childSpawn } from 'child_process';

describe('SpawnHandler', () => {
  let updateSessionSpawnInfo: Mock;
  let getSession: Mock;
  let getAncestors: Mock;
  let getDbPath: Mock;
  let mockSessionStoreGet: Mock;
  let createSession: Mock;
  let runAgent: Mock;
  let appendEventLinearized: Mock;
  let emit: Mock;
  let trackerSpawn: Mock;
  let handler: SpawnHandler;
  let mockParentSession: ActiveSession;

  beforeEach(() => {
    trackerSpawn = vi.fn();
    const updateStatus = vi.fn();
    const complete = vi.fn();
    const fail = vi.fn();

    mockParentSession = {
      workingDirectory: '/parent/dir',
      model: 'claude-3-sonnet',
      subagentTracker: {
        spawn: trackerSpawn,
        updateStatus,
        complete,
        fail,
      },
    } as unknown as ActiveSession;

    updateSessionSpawnInfo = vi.fn();
    getSession = vi.fn();
    getAncestors = vi.fn();
    getDbPath = vi.fn().mockReturnValue('/test/db.sqlite');
    mockSessionStoreGet = vi.fn().mockReturnValue(mockParentSession);
    createSession = vi.fn().mockResolvedValue({ sessionId: 'sess_sub_123' });
    runAgent = vi.fn().mockResolvedValue(undefined);
    appendEventLinearized = vi.fn();
    emit = vi.fn();

    const mockedChildSpawn = vi.mocked(childSpawn);
    mockedChildSpawn.mockImplementation(() => {
      const proc = new EventEmitter() as EventEmitter & {
        stderr: PassThrough;
        kill: Mock;
      };
      proc.stderr = new PassThrough();
      proc.kill = vi.fn();
      queueMicrotask(() => proc.emit('close', 0));
      return proc as unknown as ReturnType<typeof childSpawn>;
    });

    const mockEventStore = {
      updateSessionSpawnInfo,
      getSession,
      getAncestors,
      getDbPath,
    } as unknown as EventStore;

    handler = createSpawnHandler({
      eventStore: mockEventStore,
      sessionStore: { get: mockSessionStoreGet } as any,
      createSession,
      runAgent,
      appendEventLinearized,
      emit,
    });
  });

  describe('spawnSubsession', () => {
    it('should return error when parent session not found', async () => {
      mockSessionStoreGet.mockReturnValue(undefined);

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
        toolDenials: { tools: ['Bash'] },
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
          toolDenials: { tools: ['Bash'] },
          skills: ['git'],
          maxTurns: 30,
        })
      );
    });

    it('should include toolCallId in persisted subagent.spawned event', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      }, 'tool_call_789');

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({
          subagentSessionId: 'sess_sub_123',
          toolCallId: 'tool_call_789',
        })
      );
    });

    it('should include toolCallId as undefined when not provided', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      });

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({
          subagentSessionId: 'sess_sub_123',
          toolCallId: undefined,
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

      expect(trackerSpawn).toHaveBeenCalledWith(
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

    it('should include blocking flag in persisted subagent.spawned event', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        blocking: true,
      }, 'tc_1');

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({ blocking: true })
      );
    });

    it('should default blocking to false in persisted subagent.spawned event', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
      }, 'tc_2');

      expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123',
        'subagent.spawned',
        expect.objectContaining({ blocking: false })
      );
    });

    it('should include blocking flag in WebSocket spawned event', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        blocking: true,
      }, 'tc_1');

      expect(emit).toHaveBeenCalledWith(
        'agent_event',
        expect.objectContaining({
          type: 'agent.subagent_spawned',
          data: expect.objectContaining({
            blocking: true,
          }),
        })
      );
    });
  });

  describe('notification emission based on blocking mode', () => {
    let trackerGet: Mock;
    let trackerComplete: Mock;
    let trackerFail: Mock;
    let trackerIsTerminated: Mock;

    beforeEach(() => {
      trackerGet = vi.fn().mockReturnValue({ task: 'Test task' });
      trackerComplete = vi.fn();
      trackerFail = vi.fn();
      trackerIsTerminated = vi.fn().mockReturnValue(false);

      // Override the parent session with richer tracker for async tests
      mockParentSession = {
        workingDirectory: '/parent/dir',
        model: 'claude-3-sonnet',
        subagentTracker: {
          spawn: trackerSpawn,
          updateStatus: vi.fn(),
          complete: trackerComplete,
          fail: trackerFail,
          get: trackerGet,
          isTerminated: trackerIsTerminated,
          waitFor: vi.fn().mockResolvedValue({
            success: true,
            output: 'Result',
            summary: 'Done',
            tokenUsage: { inputTokens: 100, outputTokens: 50 },
          }),
        },
      } as unknown as ActiveSession;

      mockSessionStoreGet.mockReturnValue(mockParentSession);

      // runAgent resolves with a basic result
      runAgent.mockResolvedValue([{ stoppedReason: 'end_turn' }]);

      // getSession returns session with a headEventId
      getSession.mockResolvedValue({
        headEventId: 'evt_1',
        totalInputTokens: 100,
        totalOutputTokens: 50,
      });

      // getAncestors returns a minimal assistant message
      getAncestors.mockResolvedValue([{
        type: 'message.assistant',
        payload: { content: [{ type: 'text', text: 'Done' }], turn: 1 },
      }]);
    });

    it('should NOT emit notification.subagent_result for blocking subagent', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        blocking: true,
        timeout: 10000,
      }, 'tc_1');

      // Blocking mode awaits tracker.waitFor(), so by the time spawnSubsession returns,
      // the async runSubagentAsync has already completed

      // Wait for any remaining microtasks
      await vi.waitFor(() => expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123', 'subagent.completed', expect.anything()
      ));

      const notifCalls = appendEventLinearized.mock.calls.filter(
        ([, type]: [unknown, string]) => type === 'notification.subagent_result'
      );
      expect(notifCalls).toHaveLength(0);

      const wsCalls = emit.mock.calls.filter(
        ([, evt]: [unknown, { type?: string }]) => evt?.type === 'agent.subagent_result_available'
      );
      expect(wsCalls).toHaveLength(0);
    });

    it('should emit notification.subagent_result for non-blocking subagent', async () => {
      await handler.spawnSubsession('parent_123', {
        task: 'Test task',
        blocking: false,
      }, 'tc_2');

      // Non-blocking returns immediately; wait for async completion
      await vi.waitFor(() => expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123', 'subagent.completed', expect.anything()
      ));

      const notifCalls = appendEventLinearized.mock.calls.filter(
        ([, type]: [unknown, string]) => type === 'notification.subagent_result'
      );
      expect(notifCalls).toHaveLength(1);

      const wsCalls = emit.mock.calls.filter(
        ([, evt]: [unknown, { type?: string }]) => evt?.type === 'agent.subagent_result_available'
      );
      expect(wsCalls).toHaveLength(1);
    });

    it('should NOT emit notification for blocking subagent that fails', async () => {
      runAgent.mockRejectedValueOnce(new Error('test failure'));

      await handler.spawnSubsession('parent_123', {
        task: 'Failing task',
        blocking: true,
        timeout: 10000,
      }, 'tc_3');

      await vi.waitFor(() => expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123', 'subagent.failed', expect.anything()
      ));

      const notifCalls = appendEventLinearized.mock.calls.filter(
        ([, type]: [unknown, string]) => type === 'notification.subagent_result'
      );
      expect(notifCalls).toHaveLength(0);
    });

    it('should emit notification for non-blocking subagent that fails', async () => {
      runAgent.mockRejectedValueOnce(new Error('test failure'));

      await handler.spawnSubsession('parent_123', {
        task: 'Failing task',
        blocking: false,
      }, 'tc_4');

      await vi.waitFor(() => expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123', 'subagent.failed', expect.anything()
      ));

      const notifCalls = appendEventLinearized.mock.calls.filter(
        ([, type]: [unknown, string]) => type === 'notification.subagent_result'
      );
      expect(notifCalls).toHaveLength(1);
    });

    it('should NOT emit notification for subagent without toolCallId regardless of blocking', async () => {
      // Background subagent: no toolCallId
      await handler.spawnSubsession('parent_123', {
        task: 'Background task',
        blocking: false,
      });

      await vi.waitFor(() => expect(appendEventLinearized).toHaveBeenCalledWith(
        'parent_123', 'subagent.completed', expect.anything()
      ));

      const notifCalls = appendEventLinearized.mock.calls.filter(
        ([, type]: [unknown, string]) => type === 'notification.subagent_result'
      );
      expect(notifCalls).toHaveLength(0);
    });
  });

  describe('spawnTmuxAgent', () => {
    it('should return error when parent session not found', async () => {
      mockSessionStoreGet.mockReturnValue(undefined);

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

      expect(trackerSpawn).toHaveBeenCalledWith(
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
