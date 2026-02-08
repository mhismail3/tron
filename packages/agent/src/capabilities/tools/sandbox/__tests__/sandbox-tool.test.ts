import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('../container-runner.js', () => ({
  ContainerRunner: vi.fn(),
}));

vi.mock('../container-registry.js', () => ({
  ContainerRegistry: vi.fn(),
}));

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(),
    debug: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
}));

import { ContainerRunner } from '../container-runner.js';
import { ContainerRegistry } from '../container-registry.js';
import { SandboxTool } from '../sandbox-tool.js';
import type { SandboxParams } from '../types.js';

const MockRunner = vi.mocked(ContainerRunner);
const MockRegistry = vi.mocked(ContainerRegistry);

describe('SandboxTool', () => {
  let tool: SandboxTool;
  let mockRunner: {
    run: ReturnType<typeof vi.fn>;
    checkInstalled: ReturnType<typeof vi.fn>;
  };
  let mockRegistry: {
    getAll: ReturnType<typeof vi.fn>;
    add: ReturnType<typeof vi.fn>;
    remove: ReturnType<typeof vi.fn>;
    reconcile: ReturnType<typeof vi.fn>;
  };

  beforeEach(() => {
    mockRunner = {
      run: vi.fn().mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 }),
      checkInstalled: vi.fn().mockResolvedValue(true),
    };
    MockRunner.mockImplementation(() => mockRunner as any);

    mockRegistry = {
      getAll: vi.fn().mockReturnValue([]),
      add: vi.fn(),
      remove: vi.fn(),
      reconcile: vi.fn(),
    };
    MockRegistry.mockImplementation(() => mockRegistry as any);

    tool = new SandboxTool({
      sessionId: 'sess-test-123',
      workingDirectory: '/Users/test/project',
      tronHome: '/tmp/tron-test',
    });
  });

  describe('metadata', () => {
    it('has correct name and category', () => {
      expect(tool.name).toBe('Sandbox');
      expect(tool.category).toBe('shell');
      expect(tool.executionContract).toBe('contextual');
    });

    it('has label', () => {
      expect(tool.label).toBe('Sandbox');
    });
  });

  describe('install check', () => {
    it('returns error when container binary is not installed', async () => {
      mockRunner.checkInstalled.mockResolvedValue(false);

      const result = await tool.execute('tc-1', { action: 'list' } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBe(true);
      expect(asText(result.content)).toContain('Container CLI not found');
    });

    it('caches install check result after first call', async () => {
      mockRunner.checkInstalled.mockResolvedValue(true);

      await tool.execute('tc-1', { action: 'list' } as SandboxParams, new AbortController().signal);
      await tool.execute('tc-2', { action: 'list' } as SandboxParams, new AbortController().signal);

      expect(mockRunner.checkInstalled).toHaveBeenCalledTimes(1);
    });
  });

  describe('create', () => {
    it('generates a name and creates a detached container', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'container-id-abc\n', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'create',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();

      // Verify correct args passed to runner
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args[0]).toBe('run');
      expect(args).toContain('--detach');
      expect(args).toContain('--name');
      // Should have workspace volume mount
      expect(args.some((a: string) => a.includes('/Users/test/project') && a.includes(':/workspace'))).toBe(true);
      // Default image + sleep infinity keep-alive
      expect(args.slice(-3)).toEqual(['ubuntu:latest', 'sleep', 'infinity']);

      // Verify registered
      expect(mockRegistry.add).toHaveBeenCalledWith(
        expect.objectContaining({
          image: 'ubuntu:latest',
          createdBySession: 'sess-test-123',
          workingDirectory: '/Users/test/project',
          ports: [],
        }),
      );
    });

    it('uses custom image when specified', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'id\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'create',
        image: 'node:20',
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args.slice(-3)).toEqual(['node:20', 'sleep', 'infinity']);
      expect(mockRegistry.add).toHaveBeenCalledWith(
        expect.objectContaining({ image: 'node:20' }),
      );
    });

    it('uses agent-provided name when specified', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'id\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'create',
        name: 'my-app',
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args[args.indexOf('--name') + 1]).toBe('my-app');
      expect(mockRegistry.add).toHaveBeenCalledWith(
        expect.objectContaining({ name: 'my-app' }),
      );
    });

    it('passes port mappings', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'id\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'create',
        ports: ['3000:3000', '8080:80'],
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      const publishIdx1 = args.indexOf('--publish');
      expect(publishIdx1).toBeGreaterThan(-1);
      expect(args[publishIdx1 + 1]).toBe('3000:3000');

      expect(mockRegistry.add).toHaveBeenCalledWith(
        expect.objectContaining({ ports: ['3000:3000', '8080:80'] }),
      );
    });

    it('passes cpus, memory, env, and volumes', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'id\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'create',
        cpus: 4,
        memory: '4g',
        env: ['NODE_ENV=production'],
        volumes: ['/data:/data'],
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toContain('--cpus');
      expect(args[args.indexOf('--cpus') + 1]).toBe('4');
      expect(args).toContain('--memory');
      expect(args[args.indexOf('--memory') + 1]).toBe('4g');
      expect(args).toContain('--env');
      expect(args[args.indexOf('--env') + 1]).toBe('NODE_ENV=production');

      // Both workspace volume and custom volume
      const volumeArgs = args.filter((_: string, i: number) => i > 0 && args[i - 1] === '--volume');
      expect(volumeArgs.length).toBe(2);
      expect(volumeArgs).toContain('/data:/data');
    });

    it('returns error when runner fails', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: 'image not found\n', exitCode: 1 });

      const result = await tool.execute('tc-1', {
        action: 'create',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBe(true);
      expect(asText(result.content)).toContain('image not found');
      expect(mockRegistry.add).not.toHaveBeenCalled();
    });
  });

  describe('exec', () => {
    it('requires name and command', async () => {
      const result1 = await tool.execute('tc-1', {
        action: 'exec',
      } as SandboxParams, new AbortController().signal);
      expect(result1.isError).toBe(true);
      expect(asText(result1.content)).toContain('name');

      const result2 = await tool.execute('tc-2', {
        action: 'exec',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);
      expect(result2.isError).toBe(true);
      expect(asText(result2.content)).toContain('command');
    });

    it('wraps command in sh -c for shell syntax support', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'file1\nfile2\n', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'ls /workspace',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args[0]).toBe('exec');
      expect(args).toContain('tron-abc');
      // Command must be wrapped: sh -c "ls /workspace"
      expect(args.slice(-3)).toEqual(['sh', '-c', 'ls /workspace']);
    });

    it('supports complex shell syntax via sh -c wrapping', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'hello\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'echo hello && ls / | head -5',
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args.slice(-3)).toEqual(['sh', '-c', 'echo hello && ls / | head -5']);
    });

    it('passes workdir and env to exec', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'npm start',
        workdir: '/app',
        env: ['PORT=3000'],
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toContain('--workdir');
      expect(args[args.indexOf('--workdir') + 1]).toBe('/app');
      expect(args).toContain('--env');
      expect(args[args.indexOf('--env') + 1]).toBe('PORT=3000');
    });

    it('supports detach mode for long-running processes', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'node /workspace/server.js',
        detach: true,
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toContain('--detach');
      // --detach should come before the container name
      expect(args.indexOf('--detach')).toBeLessThan(args.indexOf('tron-abc'));
      // Still wrapped in sh -c
      expect(args.slice(-3)).toEqual(['sh', '-c', 'node /workspace/server.js']);
      expect(asText(result.content)).toContain('started in background');
    });

    it('does not include --detach by default', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'output\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'echo hi',
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).not.toContain('--detach');
    });

    it('respects custom timeout', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'long-task',
        timeout: 300000,
      } as SandboxParams, new AbortController().signal);

      const options = mockRunner.run.mock.calls[0][1];
      expect(options.timeout).toBe(300000);
    });

    it('passes abort signal to runner', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });
      const signal = new AbortController().signal;

      await tool.execute('tc-1', {
        action: 'exec',
        name: 'tron-abc',
        command: 'echo hi',
      } as SandboxParams, signal);

      const options = mockRunner.run.mock.calls[0][1];
      expect(options.signal).toBe(signal);
    });
  });

  describe('stop', () => {
    it('requires name', async () => {
      const result = await tool.execute('tc-1', {
        action: 'stop',
      } as SandboxParams, new AbortController().signal);
      expect(result.isError).toBe(true);
      expect(asText(result.content)).toContain('name');
    });

    it('stops the container', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'stop',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toEqual(['stop', 'tron-abc']);
    });
  });

  describe('start', () => {
    it('requires name', async () => {
      const result = await tool.execute('tc-1', {
        action: 'start',
      } as SandboxParams, new AbortController().signal);
      expect(result.isError).toBe(true);
    });

    it('starts the container', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'start',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toEqual(['start', 'tron-abc']);
    });
  });

  describe('remove', () => {
    it('requires name', async () => {
      const result = await tool.execute('tc-1', {
        action: 'remove',
      } as SandboxParams, new AbortController().signal);
      expect(result.isError).toBe(true);
    });

    it('stops then deletes the container and removes from registry', async () => {
      mockRunner.run.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'remove',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();

      // Should call stop then delete
      expect(mockRunner.run).toHaveBeenCalledTimes(2);
      const stopArgs = mockRunner.run.mock.calls[0][0] as string[];
      const deleteArgs = mockRunner.run.mock.calls[1][0] as string[];
      expect(stopArgs).toEqual(['stop', 'tron-abc']);
      expect(deleteArgs).toEqual(['delete', 'tron-abc']);

      expect(mockRegistry.remove).toHaveBeenCalledWith('tron-abc');
    });
  });

  describe('list', () => {
    it('reads registry and reconciles with live containers', async () => {
      mockRegistry.getAll.mockReturnValue([
        {
          name: 'tron-alive',
          image: 'ubuntu:latest',
          createdAt: '2026-01-01T00:00:00Z',
          createdBySession: 'sess-1',
          workingDirectory: '/project',
          ports: ['3000:3000'],
        },
        {
          name: 'tron-dead',
          image: 'node:20',
          createdAt: '2026-01-01T00:00:00Z',
          createdBySession: 'sess-2',
          workingDirectory: '/other',
          ports: [],
        },
      ]);

      // container list --all returns JSON with live containers
      mockRunner.run.mockResolvedValue({
        stdout: JSON.stringify([
          { name: 'tron-alive', status: 'running' },
          { name: 'untracked-container', status: 'stopped' },
        ]),
        stderr: '',
        exitCode: 0,
      });

      const result = await tool.execute('tc-1', {
        action: 'list',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const text = asText(result.content);
      expect(text).toContain('tron-alive');
      expect(text).toContain('running');
      expect(text).toContain('tron-dead');
      expect(text).toContain('gone');
    });

    it('returns message when no containers exist', async () => {
      mockRegistry.getAll.mockReturnValue([]);
      mockRunner.run.mockResolvedValue({
        stdout: '[]',
        stderr: '',
        exitCode: 0,
      });

      const result = await tool.execute('tc-1', {
        action: 'list',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      expect(asText(result.content)).toContain('No containers');
    });
  });

  describe('logs', () => {
    it('requires name', async () => {
      const result = await tool.execute('tc-1', {
        action: 'logs',
      } as SandboxParams, new AbortController().signal);
      expect(result.isError).toBe(true);
    });

    it('gets container logs', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'log line 1\nlog line 2\n', stderr: '', exitCode: 0 });

      const result = await tool.execute('tc-1', {
        action: 'logs',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBeFalsy();
      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args[0]).toBe('logs');
      expect(args).toContain('tron-abc');
    });

    it('passes tail option', async () => {
      mockRunner.run.mockResolvedValue({ stdout: 'last line\n', stderr: '', exitCode: 0 });

      await tool.execute('tc-1', {
        action: 'logs',
        name: 'tron-abc',
        tail: 50,
      } as SandboxParams, new AbortController().signal);

      const args = mockRunner.run.mock.calls[0][0] as string[];
      expect(args).toContain('--tail');
      expect(args[args.indexOf('--tail') + 1]).toBe('50');
    });
  });

  describe('unknown action', () => {
    it('returns error for unknown action', async () => {
      const result = await tool.execute('tc-1', {
        action: 'invalid' as any,
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBe(true);
      expect(asText(result.content)).toContain('Unknown action');
    });
  });

  describe('runner errors', () => {
    it('propagates runner exceptions as tool errors', async () => {
      mockRunner.run.mockRejectedValue(new Error('container binary crashed'));

      const result = await tool.execute('tc-1', {
        action: 'stop',
        name: 'tron-abc',
      } as SandboxParams, new AbortController().signal);

      expect(result.isError).toBe(true);
      expect(asText(result.content)).toContain('container binary crashed');
    });
  });
});

function asText(content: string | Array<{ type: string; text?: string }>): string {
  if (typeof content === 'string') return content;
  return content.map(c => c.text ?? '').join('');
}
