import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'events';

vi.mock('child_process', () => ({
  spawn: vi.fn(),
  execFile: vi.fn(),
}));

import { spawn, execFile } from 'child_process';
import { ContainerRunner } from '../container-runner.js';

const mockSpawn = vi.mocked(spawn);
const mockExecFile = vi.mocked(execFile);

interface MockProc extends EventEmitter {
  stdout: EventEmitter;
  stderr: EventEmitter;
  kill: ReturnType<typeof vi.fn>;
  killed: boolean;
  pid: number;
}

function createMockProcess(
  stdout = '',
  stderr = '',
  exitCode = 0,
  delay = 5,
): MockProc {
  const proc = new EventEmitter() as MockProc;
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.kill = vi.fn(() => {
    proc.killed = true;
    return true;
  });
  proc.killed = false;
  proc.pid = 12345;

  setTimeout(() => {
    if (stdout) proc.stdout.emit('data', Buffer.from(stdout));
    if (stderr) proc.stderr.emit('data', Buffer.from(stderr));
    setTimeout(() => proc.emit('close', exitCode), delay);
  }, delay);

  return proc;
}

describe('ContainerRunner', () => {
  let runner: ContainerRunner;

  beforeEach(() => {
    runner = new ContainerRunner();
  });

  describe('run', () => {
    it('spawns container binary with correct args', async () => {
      mockSpawn.mockReturnValue(createMockProcess('container-id-123\n') as any);

      await runner.run(['run', '--detach', '--name', 'tron-abc', 'ubuntu:latest']);

      expect(mockSpawn).toHaveBeenCalledWith(
        'container',
        ['run', '--detach', '--name', 'tron-abc', 'ubuntu:latest'],
        expect.objectContaining({ env: expect.any(Object) }),
      );
    });

    it('returns stdout, stderr, and exitCode', async () => {
      mockSpawn.mockReturnValue(createMockProcess('output\n', 'warning\n', 0) as any);

      const result = await runner.run(['exec', 'tron-abc', 'ls']);

      expect(result.stdout).toBe('output\n');
      expect(result.stderr).toBe('warning\n');
      expect(result.exitCode).toBe(0);
    });

    it('returns non-zero exit codes without throwing', async () => {
      mockSpawn.mockReturnValue(createMockProcess('', 'command not found\n', 127) as any);

      const result = await runner.run(['exec', 'tron-abc', 'nonexistent']);

      expect(result.exitCode).toBe(127);
      expect(result.stderr).toContain('command not found');
    });

    it('handles timeout with SIGTERM then SIGKILL', async () => {
      const proc = createMockProcess('', '', 0, 999999); // never closes
      mockSpawn.mockReturnValue(proc as any);

      const resultPromise = runner.run(['exec', 'tron-abc', 'sleep', '9999'], { timeout: 50 });

      // Wait for timeout to fire
      await vi.waitFor(() => {
        expect(proc.kill).toHaveBeenCalledWith('SIGTERM');
      }, { timeout: 200 });

      // Simulate process closing after SIGTERM
      proc.emit('close', 137);

      const result = await resultPromise;
      expect(result.exitCode).toBe(137);
    });

    it('handles abort signal', async () => {
      const proc = createMockProcess('partial output', '', 0, 999999);
      mockSpawn.mockReturnValue(proc as any);

      const controller = new AbortController();
      const resultPromise = runner.run(['exec', 'tron-abc', 'long-cmd'], { signal: controller.signal });

      // Abort after a small delay
      setTimeout(() => controller.abort(), 20);

      // Wait for abort to fire
      await vi.waitFor(() => {
        expect(proc.kill).toHaveBeenCalledWith('SIGTERM');
      }, { timeout: 200 });

      // Simulate process closing
      proc.emit('close', 130);

      const result = await resultPromise;
      expect(result.interrupted).toBe(true);
      expect(result.exitCode).toBe(130);
    });

    it('truncates large output', async () => {
      const largeOutput = 'x'.repeat(500_000);
      mockSpawn.mockReturnValue(createMockProcess(largeOutput) as any);

      const result = await runner.run(['exec', 'tron-abc', 'cat', 'bigfile']);

      expect(result.stdout.length).toBeLessThan(500_000);
      expect(result.stdout).toContain('[Output truncated');
    });

    it('propagates spawn errors', async () => {
      const proc = new EventEmitter() as MockProc;
      proc.stdout = new EventEmitter();
      proc.stderr = new EventEmitter();
      proc.kill = vi.fn();
      proc.killed = false;
      proc.pid = 0;

      mockSpawn.mockReturnValue(proc as any);

      const resultPromise = runner.run(['run', 'ubuntu:latest']);

      // Emit error
      setTimeout(() => proc.emit('error', new Error('spawn ENOENT')), 5);

      await expect(resultPromise).rejects.toThrow('spawn ENOENT');
    });
  });

  describe('checkInstalled', () => {
    it('returns true when container binary exists', async () => {
      mockExecFile.mockImplementation((_cmd, _args, callback: any) => {
        callback(null, '/usr/local/bin/container\n', '');
        return {} as any;
      });

      const installed = await runner.checkInstalled();
      expect(installed).toBe(true);
    });

    it('returns false when container binary is missing', async () => {
      mockExecFile.mockImplementation((_cmd, _args, callback: any) => {
        callback(new Error('not found'), '', '');
        return {} as any;
      });

      const installed = await runner.checkInstalled();
      expect(installed).toBe(false);
    });
  });
});
