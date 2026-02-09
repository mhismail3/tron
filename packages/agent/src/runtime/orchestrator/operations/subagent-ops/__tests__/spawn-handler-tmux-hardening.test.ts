/**
 * @fileoverview TDD tests for tmux spawn hardening in SpawnHandler
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

import { spawn } from 'child_process';

interface MockChildProcess extends EventEmitter {
  stdout: PassThrough;
  stderr: PassThrough;
  unref: Mock;
  kill: Mock;
}

function createMockChildProcess(): MockChildProcess {
  const proc = new EventEmitter() as MockChildProcess;
  proc.stdout = new PassThrough();
  proc.stderr = new PassThrough();
  proc.unref = vi.fn();
  proc.kill = vi.fn();
  return proc;
}

describe('SpawnHandler tmux hardening', () => {
  const mockedSpawn = vi.mocked(spawn);

  let appendEventLinearized: Mock;
  let mockSessionStoreGet: Mock;
  let handler: SpawnHandler;

  beforeEach(() => {
    vi.clearAllMocks();

    const mockParentSession = {
      workingDirectory: '/parent/dir',
      model: 'claude-3-sonnet',
      subagentTracker: {
        spawn: vi.fn(),
        updateStatus: vi.fn(),
        complete: vi.fn(),
        fail: vi.fn(),
      },
    } as unknown as ActiveSession;

    mockSessionStoreGet = vi.fn().mockReturnValue(mockParentSession);
    appendEventLinearized = vi.fn();

    const mockEventStore = {
      getDbPath: vi.fn().mockReturnValue('/test/db.sqlite'),
    } as unknown as EventStore;

    handler = createSpawnHandler({
      eventStore: mockEventStore,
      sessionStore: { get: mockSessionStoreGet } as any,
      createSession: vi.fn(),
      runAgent: vi.fn(),
      appendEventLinearized,
      emit: vi.fn(),
    });
  });

  it('uses argument-safe tmux invocation without shell-concatenated tron command', async () => {
    const newSessionProc = createMockChildProcess();
    const hasSessionProc = createMockChildProcess();

    mockedSpawn
      .mockReturnValueOnce(newSessionProc as unknown as ReturnType<typeof spawn>)
      .mockReturnValueOnce(hasSessionProc as unknown as ReturnType<typeof spawn>);

    setImmediate(() => newSessionProc.emit('close', 0));
    setImmediate(() => hasSessionProc.emit('close', 0));

    const result = await handler.spawnTmuxAgent('parent_123', {
      task: 'check this; rm -rf /',
      sessionName: 'safe-session',
    });

    expect(result.success).toBe(true);

    expect(mockedSpawn).toHaveBeenCalledTimes(2);
    const [binary, args] = mockedSpawn.mock.calls[0] ?? [];
    expect(binary).toBe('tmux');

    const argList = args as string[];
    expect(argList).toContain('--');
    expect(argList).toContain('tron');
    expect(argList).toContain('--spawn-task');
    expect(argList).toContain('check this; rm -rf /');
    expect(argList.some((arg) => arg.startsWith('--spawn-task='))).toBe(false);
    expect(argList.some((arg) => arg.includes('"'))).toBe(false);
  });

  it('rejects malformed tmux session names and does not spawn', async () => {
    const result = await handler.spawnTmuxAgent('parent_123', {
      task: 'test task',
      sessionName: 'bad;session',
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('Invalid tmux session name');
    expect(mockedSpawn).not.toHaveBeenCalled();
    expect(appendEventLinearized).not.toHaveBeenCalled();
  });

  it('fails when tmux startup command exits non-zero and never emits spawned event', async () => {
    const newSessionProc = createMockChildProcess();
    mockedSpawn.mockReturnValueOnce(newSessionProc as unknown as ReturnType<typeof spawn>);

    setImmediate(() => {
      newSessionProc.stderr.write('tmux failed');
      newSessionProc.emit('close', 1);
    });

    const result = await handler.spawnTmuxAgent('parent_123', {
      task: 'test task',
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('tmux failed');
    expect(appendEventLinearized).not.toHaveBeenCalled();
  });

  it('fails when startup verification cannot find tmux session', async () => {
    const newSessionProc = createMockChildProcess();
    const hasSessionProc = createMockChildProcess();

    mockedSpawn
      .mockReturnValueOnce(newSessionProc as unknown as ReturnType<typeof spawn>)
      .mockReturnValueOnce(hasSessionProc as unknown as ReturnType<typeof spawn>);

    setImmediate(() => newSessionProc.emit('close', 0));
    setImmediate(() => {
      hasSessionProc.stderr.write('no such session');
      hasSessionProc.emit('close', 1);
    });

    const result = await handler.spawnTmuxAgent('parent_123', {
      task: 'test task',
      sessionName: 'check-startup',
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('no such session');
    expect(appendEventLinearized).not.toHaveBeenCalled();
  });
});
