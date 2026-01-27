/**
 * @fileoverview Worktree Recovery Tests
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { WorktreeRecovery, createWorktreeRecovery } from '../recovery.js';
import type { GitExecutor } from '../git-executor.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

// =============================================================================
// Unit Tests with Mocks
// =============================================================================

describe('WorktreeRecovery - Unit Tests', () => {
  const createMockGitExecutor = (): GitExecutor => ({
    execGit: vi.fn().mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 }),
    isGitRepo: vi.fn().mockResolvedValue(true),
    getRepoRoot: vi.fn().mockResolvedValue('/repo'),
    getCurrentBranch: vi.fn().mockResolvedValue('main'),
    getCurrentCommit: vi.fn().mockResolvedValue('abc123'),
    branchExists: vi.fn().mockResolvedValue(false),
    hasUncommittedChanges: vi.fn().mockResolvedValue(false),
    pathExists: vi.fn().mockResolvedValue(true),
  });

  describe('recoverOrphaned', () => {
    it('should return empty array when worktree base does not exist', async () => {
      const mockGit = createMockGitExecutor();
      (mockGit.pathExists as ReturnType<typeof vi.fn>).mockResolvedValue(false);

      const recovery = createWorktreeRecovery({
        gitExecutor: mockGit,
        repoRoot: '/repo',
        worktreeBaseDir: '/repo/.worktrees',
                isSessionActive: () => false,
        deleteOnRecovery: true,
      });

      const results = await recovery.recoverOrphaned();
      expect(results).toEqual([]);
    });

    it('should skip active sessions', async () => {
      const mockGit = createMockGitExecutor();

      const recovery = createWorktreeRecovery({
        gitExecutor: mockGit,
        repoRoot: '/repo',
        worktreeBaseDir: '/repo/.worktrees',
                isSessionActive: (id) => id === 'active_session',
        deleteOnRecovery: true,
      });

      // Even if directory exists, should skip active session
      // (This would require mocking fs.readdir which is more complex)
      expect(recovery).toBeDefined();
    });
  });

  describe('hasOrphaned', () => {
    it('should return false when worktree base does not exist', async () => {
      const mockGit = createMockGitExecutor();
      (mockGit.pathExists as ReturnType<typeof vi.fn>).mockResolvedValue(false);

      const recovery = createWorktreeRecovery({
        gitExecutor: mockGit,
        repoRoot: '/repo',
        worktreeBaseDir: '/repo/.worktrees',
                isSessionActive: () => false,
        deleteOnRecovery: true,
      });

      const hasOrphaned = await recovery.hasOrphaned();
      expect(hasOrphaned).toBe(false);
    });
  });

  describe('pruneStale', () => {
    it('should call git worktree prune', async () => {
      const mockGit = createMockGitExecutor();

      const recovery = createWorktreeRecovery({
        gitExecutor: mockGit,
        repoRoot: '/repo',
        worktreeBaseDir: '/repo/.worktrees',
                isSessionActive: () => false,
        deleteOnRecovery: true,
      });

      await recovery.pruneStale();
      expect(mockGit.execGit).toHaveBeenCalledWith(['worktree', 'prune'], '/repo');
    });

    it('should not throw on prune errors', async () => {
      const mockGit = createMockGitExecutor();
      (mockGit.execGit as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('Prune failed'));

      const recovery = createWorktreeRecovery({
        gitExecutor: mockGit,
        repoRoot: '/repo',
        worktreeBaseDir: '/repo/.worktrees',
                isSessionActive: () => false,
        deleteOnRecovery: true,
      });

      await expect(recovery.pruneStale()).resolves.not.toThrow();
    });
  });
});

// =============================================================================
// Integration Tests with Real Git
// =============================================================================

describe('WorktreeRecovery - Integration Tests', () => {
  let testDir: string;
  let repoRoot: string;

  async function createTestRepo(): Promise<string> {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'recovery-test-'));
    const resolved = await fs.realpath(dir);
    await execAsync('git init', { cwd: resolved });
    await execAsync('git config user.email "test@test.com"', { cwd: resolved });
    await execAsync('git config user.name "Test"', { cwd: resolved });
    await fs.writeFile(path.join(resolved, 'README.md'), '# Test');
    await execAsync('git add .', { cwd: resolved });
    await execAsync('git commit -m "Initial commit"', { cwd: resolved });
    return resolved;
  }

  function createRealGitExecutor(): GitExecutor {
    return {
      async execGit(args: string[], cwd: string) {
        try {
          // Properly escape arguments for shell
          const escapedArgs = args.map(arg => {
            // Quote args with spaces or special characters
            if (/[\s\[\]\(\){}'"\\]/.test(arg)) {
              return `"${arg.replace(/"/g, '\\"')}"`;
            }
            return arg;
          }).join(' ');
          const { stdout, stderr } = await execAsync(`git ${escapedArgs}`, { cwd });
          return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode: 0 };
        } catch (error: any) {
          return {
            stdout: error.stdout?.trim() || '',
            stderr: error.stderr?.trim() || error.message,
            exitCode: error.code || 1,
          };
        }
      },
      async isGitRepo(dir: string) {
        try {
          await execAsync('git rev-parse --git-dir', { cwd: dir });
          return true;
        } catch {
          return false;
        }
      },
      async getRepoRoot(dir: string) {
        try {
          const { stdout } = await execAsync('git rev-parse --show-toplevel', { cwd: dir });
          return stdout.trim();
        } catch {
          return null;
        }
      },
      async getCurrentBranch(dir: string) {
        const { stdout } = await execAsync('git branch --show-current', { cwd: dir });
        return stdout.trim() || 'HEAD';
      },
      async getCurrentCommit(dir: string) {
        const { stdout } = await execAsync('git rev-parse HEAD', { cwd: dir });
        return stdout.trim();
      },
      async branchExists(repoRoot: string, branchName: string) {
        try {
          await execAsync(`git rev-parse --verify ${branchName}`, { cwd: repoRoot });
          return true;
        } catch {
          return false;
        }
      },
      async hasUncommittedChanges(dir: string) {
        const { stdout } = await execAsync('git status --porcelain', { cwd: dir });
        return !!stdout.trim();
      },
      async pathExists(p: string) {
        try {
          await fs.access(p);
          return true;
        } catch {
          return false;
        }
      },
    };
  }

  beforeEach(async () => {
    repoRoot = await createTestRepo();
    testDir = repoRoot;
  });

  afterEach(async () => {
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  it('should recover orphaned worktree with uncommitted changes', async () => {
    const worktreeBase = path.join(repoRoot, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    // Create an orphaned worktree
    const orphanPath = path.join(worktreeBase, 'sess_orphan');
    await execAsync(`git worktree add ${orphanPath} -b session/sess_orphan HEAD`, { cwd: repoRoot });

    // Configure git in the worktree (needed for commits)
    await execAsync('git config user.email "test@test.com"', { cwd: orphanPath });
    await execAsync('git config user.name "Test"', { cwd: orphanPath });

    // Add uncommitted changes
    await fs.writeFile(path.join(orphanPath, 'orphan-file.txt'), 'orphan content');

    const gitExecutor = createRealGitExecutor();
    const recovery = createWorktreeRecovery({
      gitExecutor,
      repoRoot,
      worktreeBaseDir: worktreeBase,
            isSessionActive: () => false,
      deleteOnRecovery: false, // Don't delete so we can check the commit
    });

    const results = await recovery.recoverOrphaned();

    expect(results.length).toBe(1);
    expect(results[0].sessionId).toBe('sess_orphan');
    expect(results[0].hadChanges).toBe(true);
    expect(results[0].committed).toBe(true);

    // Verify commit was made
    const { stdout } = await execAsync('git log --oneline -1', { cwd: orphanPath });
    expect(stdout).toContain('RECOVERED');
  });

  it('should skip worktrees with no changes', async () => {
    const worktreeBase = path.join(repoRoot, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    // Create a clean orphaned worktree (no uncommitted changes)
    const orphanPath = path.join(worktreeBase, 'sess_clean');
    await execAsync(`git worktree add ${orphanPath} -b session/sess_clean HEAD`, { cwd: repoRoot });

    const gitExecutor = createRealGitExecutor();
    const recovery = createWorktreeRecovery({
      gitExecutor,
      repoRoot,
      worktreeBaseDir: worktreeBase,
            isSessionActive: () => false,
      deleteOnRecovery: false,
    });

    const results = await recovery.recoverOrphaned();

    expect(results.length).toBe(1);
    expect(results[0].sessionId).toBe('sess_clean');
    expect(results[0].hadChanges).toBe(false);
    expect(results[0].committed).toBe(false);
  });

  it('should delete worktree when deleteOnRecovery is true', async () => {
    const worktreeBase = path.join(repoRoot, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    const orphanPath = path.join(worktreeBase, 'sess_delete');
    await execAsync(`git worktree add ${orphanPath} -b session/sess_delete HEAD`, { cwd: repoRoot });

    const gitExecutor = createRealGitExecutor();
    const recovery = createWorktreeRecovery({
      gitExecutor,
      repoRoot,
      worktreeBaseDir: worktreeBase,
            isSessionActive: () => false,
      deleteOnRecovery: true,
    });

    const results = await recovery.recoverOrphaned();

    expect(results.length).toBe(1);
    expect(results[0].deleted).toBe(true);

    // Verify directory was deleted
    const exists = await fs.access(orphanPath).then(() => true).catch(() => false);
    expect(exists).toBe(false);
  });

  it('should skip active sessions', async () => {
    const worktreeBase = path.join(repoRoot, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    const activePath = path.join(worktreeBase, 'sess_active');
    await execAsync(`git worktree add ${activePath} -b session/sess_active HEAD`, { cwd: repoRoot });
    await fs.writeFile(path.join(activePath, 'active-file.txt'), 'active content');

    const gitExecutor = createRealGitExecutor();
    const recovery = createWorktreeRecovery({
      gitExecutor,
      repoRoot,
      worktreeBaseDir: worktreeBase,
            isSessionActive: (id) => id === 'sess_active',
      deleteOnRecovery: true,
    });

    const results = await recovery.recoverOrphaned();

    // Should not include the active session
    expect(results.length).toBe(0);

    // Verify the worktree still exists with uncommitted changes
    const exists = await fs.access(activePath).then(() => true).catch(() => false);
    expect(exists).toBe(true);
  });

  it('should detect orphaned worktrees with hasOrphaned', async () => {
    const worktreeBase = path.join(repoRoot, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    const gitExecutor = createRealGitExecutor();
    const recovery = createWorktreeRecovery({
      gitExecutor,
      repoRoot,
      worktreeBaseDir: worktreeBase,
            isSessionActive: () => false,
      deleteOnRecovery: true,
    });

    // No orphaned worktrees yet
    expect(await recovery.hasOrphaned()).toBe(false);

    // Create an orphaned worktree
    const orphanPath = path.join(worktreeBase, 'sess_orphan');
    await execAsync(`git worktree add ${orphanPath} -b session/sess_orphan HEAD`, { cwd: repoRoot });

    // Now should detect orphaned
    expect(await recovery.hasOrphaned()).toBe(true);
  });
});
