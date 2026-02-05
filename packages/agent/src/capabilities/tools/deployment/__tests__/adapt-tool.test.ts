import { describe, it, expect, vi, beforeEach } from 'vitest';
import { spawnSync, spawn } from 'child_process';
import { readFileSync, existsSync, unlinkSync, writeFileSync } from 'fs';
import { AdaptTool } from '../adapt-tool.js';
import type { AdaptToolConfig } from '../types.js';

vi.mock('child_process', () => ({
  spawnSync: vi.fn(),
  spawn: vi.fn(),
}));

vi.mock('fs', () => ({
  readFileSync: vi.fn(),
  existsSync: vi.fn(),
  unlinkSync: vi.fn(),
  writeFileSync: vi.fn(),
}));

const mockSpawnSync = vi.mocked(spawnSync);
const mockSpawn = vi.mocked(spawn);
const mockReadFileSync = vi.mocked(readFileSync);
const mockExistsSync = vi.mocked(existsSync);
const mockUnlinkSync = vi.mocked(unlinkSync);
const mockWriteFileSync = vi.mocked(writeFileSync);

function createMockChild() {
  return {
    unref: vi.fn(),
    pid: 99999,
    on: vi.fn(),
    stdout: null,
    stderr: null,
    stdin: null,
    kill: vi.fn(),
    ref: vi.fn(),
    connected: false,
    exitCode: null,
    signalCode: null,
    spawnargs: [],
    spawnfile: '',
    killed: false,
    send: vi.fn(),
    disconnect: vi.fn(),
    channel: undefined,
    stdio: [] as any,
    [Symbol.dispose]: vi.fn(),
  } as unknown as ReturnType<typeof spawn>;
}

const defaultConfig: AdaptToolConfig = {
  repoRoot: '/home/user/project',
  tronHome: '/home/user/.tron',
  tronScript: '/home/user/project/scripts/tron',
};

describe('AdaptTool', () => {
  let tool: AdaptTool;

  beforeEach(() => {
    tool = new AdaptTool(defaultConfig);
    // Default: no lock file
    mockExistsSync.mockReturnValue(false);
  });

  // =========================================================================
  // Tool definition
  // =========================================================================

  describe('tool definition', () => {
    it('has name Adapt', () => {
      expect(tool.name).toBe('Adapt');
    });

    it('has description mentioning self-deploy', () => {
      expect(tool.description).toMatch(/deploy/i);
    });

    it('has parameters schema with action enum', () => {
      const actionProp = tool.parameters.properties!.action;
      expect(actionProp.enum).toEqual(['deploy', 'status', 'rollback']);
    });

    it('requires confirmation', () => {
      expect(tool.requiresConfirmation).toBe(true);
    });

    it('has custom category', () => {
      expect(tool.category).toBe('custom');
    });
  });

  // =========================================================================
  // deploy action
  // =========================================================================

  describe('deploy action', () => {
    it('runs spawnSync with deploy --prepare and correct cwd', async () => {
      mockSpawnSync.mockReturnValue({
        status: 0,
        stdout: 'Tests passed\nBuild complete',
        stderr: '',
        pid: 1234,
        output: [],
        signal: null,
      });
      mockSpawn.mockReturnValue(createMockChild());

      await tool.execute({ action: 'deploy' });

      expect(mockSpawnSync).toHaveBeenCalledWith(
        defaultConfig.tronScript,
        ['deploy', '--prepare'],
        expect.objectContaining({
          cwd: defaultConfig.repoRoot,
          encoding: 'utf-8',
        })
      );
    });

    it('spawns detached swap process on prepare success', async () => {
      mockSpawnSync.mockReturnValue({
        status: 0,
        stdout: 'ok',
        stderr: '',
        pid: 1234,
        output: [],
        signal: null,
      });
      const mockChild = createMockChild();
      mockSpawn.mockReturnValue(mockChild);

      await tool.execute({ action: 'deploy' });

      expect(mockSpawn).toHaveBeenCalledWith(
        defaultConfig.tronScript,
        ['deploy', '--swap', '--delay', '3'],
        expect.objectContaining({
          cwd: defaultConfig.repoRoot,
          detached: true,
          stdio: 'ignore',
        })
      );
      expect(mockChild.unref).toHaveBeenCalled();
    });

    it('returns error with output on prepare failure, does NOT spawn swap', async () => {
      mockSpawnSync.mockReturnValue({
        status: 1,
        stdout: 'Running tests...',
        stderr: 'FAIL src/foo.test.ts',
        pid: 1234,
        output: [],
        signal: null,
      });

      const result = await tool.execute({ action: 'deploy' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('FAIL');
      expect(mockSpawn).not.toHaveBeenCalled();
    });

    it('returns informative success message', async () => {
      mockSpawnSync.mockReturnValue({
        status: 0,
        stdout: 'ok',
        stderr: '',
        pid: 1234,
        output: [],
        signal: null,
      });
      mockSpawn.mockReturnValue(createMockChild());

      const result = await tool.execute({ action: 'deploy' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toMatch(/3 seconds/);
      expect(result.content).toMatch(/status/i);
    });

    it('rejects if lock file exists with live PID', async () => {
      mockExistsSync.mockImplementation((path: any) => {
        if (String(path).includes('deploy.lock')) return true;
        return false;
      });
      mockReadFileSync.mockReturnValue('12345');

      const originalKill = process.kill;
      process.kill = vi.fn() as any;

      const result = await tool.execute({ action: 'deploy' });

      expect(result.isError).toBe(true);
      expect(result.content).toMatch(/in progress|locked/i);

      process.kill = originalKill;
    });

    it('cleans stale lock when PID is dead', async () => {
      mockExistsSync.mockImplementation((path: any) => {
        if (String(path).includes('deploy.lock')) return true;
        return false;
      });
      mockReadFileSync.mockReturnValue('99999');

      const originalKill = process.kill;
      process.kill = vi.fn(() => { throw new Error('ESRCH'); }) as any;

      mockSpawnSync.mockReturnValue({
        status: 0,
        stdout: 'ok',
        stderr: '',
        pid: 1234,
        output: [],
        signal: null,
      });
      mockSpawn.mockReturnValue(createMockChild());

      const result = await tool.execute({ action: 'deploy' });

      expect(result.isError).toBeFalsy();
      expect(mockUnlinkSync).toHaveBeenCalled();

      process.kill = originalKill;
    });

    it('releases lock on prepare failure', async () => {
      mockSpawnSync.mockReturnValue({
        status: 1,
        stdout: '',
        stderr: 'error',
        pid: 1234,
        output: [],
        signal: null,
      });

      await tool.execute({ action: 'deploy' });

      expect(mockUnlinkSync).toHaveBeenCalled();
    });
  });

  // =========================================================================
  // status action
  // =========================================================================

  describe('status action', () => {
    it('reads and returns parsed last-deployment.json', async () => {
      mockExistsSync.mockImplementation((path: any) => {
        if (String(path).includes('last-deployment.json')) return true;
        return false;
      });
      mockReadFileSync.mockReturnValue(JSON.stringify({
        status: 'success',
        timestamp: '2026-02-05T12:00:00Z',
        commit: 'abc1234',
        previousCommit: 'def5678',
        error: null,
      }));

      const result = await tool.execute({ action: 'status' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('success');
      expect(result.content).toContain('abc1234');
    });

    it('returns "no deployment recorded" if file missing', async () => {
      mockExistsSync.mockReturnValue(false);

      const result = await tool.execute({ action: 'status' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toMatch(/no deployment/i);
    });

    it('returns error on invalid JSON', async () => {
      mockExistsSync.mockImplementation((path: any) => {
        if (String(path).includes('last-deployment.json')) return true;
        return false;
      });
      mockReadFileSync.mockReturnValue('not json{{{');

      const result = await tool.execute({ action: 'status' });

      expect(result.isError).toBe(true);
    });
  });

  // =========================================================================
  // rollback action
  // =========================================================================

  describe('rollback action', () => {
    it('spawns detached rollback process', async () => {
      const mockChild = createMockChild();
      mockSpawn.mockReturnValue(mockChild);

      const result = await tool.execute({ action: 'rollback' });

      expect(mockSpawn).toHaveBeenCalledWith(
        defaultConfig.tronScript,
        ['rollback', '--yes', '--delay', '3'],
        expect.objectContaining({
          cwd: defaultConfig.repoRoot,
          detached: true,
          stdio: 'ignore',
        })
      );
      expect(mockChild.unref).toHaveBeenCalled();
      expect(result.isError).toBeFalsy();
      expect(result.content).toMatch(/rollback/i);
    });

    it('rejects if locked', async () => {
      mockExistsSync.mockImplementation((path: any) => {
        if (String(path).includes('deploy.lock')) return true;
        return false;
      });
      mockReadFileSync.mockReturnValue('12345');

      const originalKill = process.kill;
      process.kill = vi.fn() as any;

      const result = await tool.execute({ action: 'rollback' });

      expect(result.isError).toBe(true);
      expect(result.content).toMatch(/in progress|locked/i);

      process.kill = originalKill;
    });
  });

  // =========================================================================
  // unknown action
  // =========================================================================

  describe('unknown action', () => {
    it('returns error for unknown action', async () => {
      const result = await tool.execute({ action: 'unknown' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });
  });
});
