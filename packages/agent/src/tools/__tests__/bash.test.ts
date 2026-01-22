/**
 * @fileoverview Tests for Bash tool
 *
 * TDD: Tests for shell command execution
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { spawn } from 'child_process';
import { BashTool } from '../bash.js';

// Mock child_process
vi.mock('child_process', () => ({
  spawn: vi.fn(),
}));

const mockSpawn = vi.mocked(spawn);

function createMockProcess(stdout = '', stderr = '', exitCode = 0) {
  const mockProcess = {
    stdout: {
      on: vi.fn((event: string, cb: (data: Buffer) => void) => {
        if (event === 'data' && stdout) {
          setTimeout(() => cb(Buffer.from(stdout)), 0);
        }
      }),
    },
    stderr: {
      on: vi.fn((event: string, cb: (data: Buffer) => void) => {
        if (event === 'data' && stderr) {
          setTimeout(() => cb(Buffer.from(stderr)), 0);
        }
      }),
    },
    on: vi.fn((event: string, cb: (code: number) => void) => {
      if (event === 'close') {
        setTimeout(() => cb(exitCode), 10);
      }
    }),
    kill: vi.fn(),
    pid: 12345,
  };
  return mockProcess;
}

describe('BashTool', () => {
  let bashTool: BashTool;

  beforeEach(() => {
    bashTool = new BashTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(bashTool.name).toBe('Bash');
      expect(bashTool.description).toContain('command');
    });

    it('should define required parameters', () => {
      const params = bashTool.parameters;
      expect(params.properties).toHaveProperty('command');
      expect(params.required).toContain('command');
    });

    it('should support optional timeout parameter', () => {
      const params = bashTool.parameters;
      expect(params.properties).toHaveProperty('timeout');
    });

    it('should support optional description parameter', () => {
      const params = bashTool.parameters;
      expect(params.properties).toHaveProperty('description');
    });
  });

  describe('execute', () => {
    it('should execute command and return stdout', async () => {
      mockSpawn.mockReturnValue(createMockProcess('Hello, world!\n') as any);

      const result = await bashTool.execute({ command: 'echo "Hello, world!"' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Hello, world!');
    });

    it('should include stderr in output', async () => {
      mockSpawn.mockReturnValue(createMockProcess('', 'Warning: something\n', 0) as any);

      const result = await bashTool.execute({ command: 'some-command' });

      expect(result.content).toContain('Warning');
    });

    it('should report non-zero exit codes as errors', async () => {
      mockSpawn.mockReturnValue(createMockProcess('', 'Error occurred\n', 1) as any);

      const result = await bashTool.execute({ command: 'failing-command' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('exit code');
    });

    it('should execute in working directory', async () => {
      mockSpawn.mockReturnValue(createMockProcess() as any);

      await bashTool.execute({ command: 'ls' });

      expect(mockSpawn).toHaveBeenCalledWith(
        expect.any(String),
        expect.any(Array),
        expect.objectContaining({ cwd: '/test/project' })
      );
    });

    it('should handle command timeout', async () => {
      // Instead of mocking, test the actual timeout message generation
      // This avoids the complexity of mocking the streaming process
      const mockProcess = {
        stdout: {
          on: vi.fn(),
        },
        stderr: {
          on: vi.fn(),
        },
        on: vi.fn((event: string, cb: (code: number) => void) => {
          // Simulate a delayed completion that exceeds timeout
          if (event === 'close') {
            setTimeout(() => cb(0), 200);
          }
        }),
        kill: vi.fn(),
        pid: 12345,
      };
      mockSpawn.mockReturnValue(mockProcess as any);

      const bashToolWithShortTimeout = new BashTool({
        workingDirectory: '/test/project',
        defaultTimeout: 50,
      });

      const result = await bashToolWithShortTimeout.execute({
        command: 'sleep 10',
        timeout: 50,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('timed out');
      expect(mockProcess.kill).toHaveBeenCalled();
    }, 10000);

    it('should include exit code in details', async () => {
      mockSpawn.mockReturnValue(createMockProcess('output\n', '', 0) as any);

      const result = await bashTool.execute({ command: 'ls' });

      expect(result.details).toHaveProperty('exitCode', 0);
    });

    it('should include duration in details', async () => {
      mockSpawn.mockReturnValue(createMockProcess('output\n', '', 0) as any);

      const result = await bashTool.execute({ command: 'ls' });

      expect(result.details).toHaveProperty('durationMs');
      expect(typeof result.details?.durationMs).toBe('number');
    });

    it('should truncate very long output', async () => {
      const longOutput = 'a'.repeat(100000);
      mockSpawn.mockReturnValue(createMockProcess(longOutput) as any);

      const result = await bashTool.execute({ command: 'cat large-file' });

      // Should truncate and indicate truncation
      expect(result.content.length).toBeLessThan(100000);
      expect(result.content).toContain('truncated');
    });

    it('should block dangerous commands', async () => {
      const result = await bashTool.execute({ command: 'rm -rf /' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('blocked');
    });

    it('should block sudo commands', async () => {
      const result = await bashTool.execute({ command: 'sudo apt update' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('blocked');
    });
  });

  describe('command sanitization', () => {
    it('should reject commands with shell injection', async () => {
      const result = await bashTool.execute({ command: 'echo "test"; rm -rf /' });

      // Note: The tool should execute commands as-is since they're controlled
      // by the LLM, but dangerous patterns should still be blocked
      expect(result.isError).toBe(true);
    });
  });
});
