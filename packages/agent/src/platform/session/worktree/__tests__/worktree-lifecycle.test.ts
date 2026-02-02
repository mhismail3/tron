/**
 * @fileoverview Tests for WorktreeLifecycle
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { WorktreeLifecycle, createWorktreeLifecycle } from '../worktree-lifecycle.js';
import { GitExecutor, createGitExecutor } from '../git-executor.js';

// =============================================================================
// Test Helpers
// =============================================================================

let testDir: string;
let gitRepoDir: string;
let worktreeBaseDir: string;
let gitExecutor: GitExecutor;

async function setupTestDirs() {
  const tmpBase = await fs.realpath(os.tmpdir());
  testDir = path.join(tmpBase, `worktree-lifecycle-test-${Date.now()}`);
  gitRepoDir = path.join(testDir, 'git-repo');
  worktreeBaseDir = path.join(testDir, 'worktrees');

  await fs.mkdir(gitRepoDir, { recursive: true });
  await fs.mkdir(worktreeBaseDir, { recursive: true });

  // Initialize git repo
  const { execSync } = await import('child_process');
  execSync('git init', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.name "Test User"', { cwd: gitRepoDir, stdio: 'pipe' });

  // Create initial commit
  await fs.writeFile(path.join(gitRepoDir, 'test.txt'), 'test content');
  execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git commit -m "Initial commit"', { cwd: gitRepoDir, stdio: 'pipe' });

  gitExecutor = createGitExecutor();
}

async function cleanupTestDirs() {
  if (testDir) {
    await fs.rm(testDir, { recursive: true, force: true });
  }
}

// =============================================================================
// Tests
// =============================================================================

describe('WorktreeLifecycle', () => {
  let lifecycle: WorktreeLifecycle;

  beforeEach(async () => {
    await setupTestDirs();
    lifecycle = createWorktreeLifecycle({
      gitExecutor,
      repoRoot: gitRepoDir,
      worktreeBaseDir,
      branchPrefix: 'session/',
    });
  });

  afterEach(async () => {
    await cleanupTestDirs();
  });

  describe('createWorktree', () => {
    it('should create worktree with new branch', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'test-session');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);

      await lifecycle.createWorktree(worktreePath, 'session/test-session', baseCommit);

      // Verify worktree exists
      const exists = await gitExecutor.pathExists(worktreePath);
      expect(exists).toBe(true);

      // Verify branch was created
      const branchExists = await gitExecutor.branchExists(gitRepoDir, 'session/test-session');
      expect(branchExists).toBe(true);

      // Verify worktree is on correct branch
      const branch = await gitExecutor.getCurrentBranch(worktreePath);
      expect(branch).toBe('session/test-session');
    });

    it('should create worktree from specific commit', async () => {
      // Create a second commit
      const { execSync } = await import('child_process');
      await fs.writeFile(path.join(gitRepoDir, 'second.txt'), 'second content');
      execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
      execSync('git commit -m "Second commit"', { cwd: gitRepoDir, stdio: 'pipe' });

      // Get first commit hash
      const logResult = await gitExecutor.execGit(['log', '--oneline', '-2'], gitRepoDir);
      const commits = logResult.stdout.split('\n');
      const firstCommitHash = commits[1].split(' ')[0];

      const worktreePath = path.join(worktreeBaseDir, 'from-commit');
      await lifecycle.createWorktree(worktreePath, 'session/from-commit', firstCommitHash);

      // Verify worktree is at first commit (doesn't have second.txt)
      const hasSecondFile = await gitExecutor.pathExists(path.join(worktreePath, 'second.txt'));
      expect(hasSecondFile).toBe(false);
    });

    it('should handle existing branch by checking it out', async () => {
      // Create branch first
      const { execSync } = await import('child_process');
      execSync('git branch session/existing-branch', { cwd: gitRepoDir, stdio: 'pipe' });

      const worktreePath = path.join(worktreeBaseDir, 'existing-branch');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);

      // Should not throw even though branch exists
      await lifecycle.createWorktree(worktreePath, 'session/existing-branch', baseCommit);

      const exists = await gitExecutor.pathExists(worktreePath);
      expect(exists).toBe(true);
    });
  });

  describe('removeWorktree', () => {
    it('should remove worktree directory', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'to-remove');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);
      await lifecycle.createWorktree(worktreePath, 'session/to-remove', baseCommit);

      await lifecycle.removeWorktree(worktreePath);

      const exists = await gitExecutor.pathExists(worktreePath);
      expect(exists).toBe(false);
    });

    it('should optionally delete branch', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'delete-branch');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);
      await lifecycle.createWorktree(worktreePath, 'session/delete-branch', baseCommit);

      await lifecycle.removeWorktree(worktreePath, { deleteBranch: true });

      const branchExists = await gitExecutor.branchExists(gitRepoDir, 'session/delete-branch');
      expect(branchExists).toBe(false);
    });

    it('should preserve branch by default', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'preserve-branch');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);
      await lifecycle.createWorktree(worktreePath, 'session/preserve-branch', baseCommit);

      await lifecycle.removeWorktree(worktreePath);

      const branchExists = await gitExecutor.branchExists(gitRepoDir, 'session/preserve-branch');
      expect(branchExists).toBe(true);
    });

    it('should handle non-existing worktree gracefully', async () => {
      const nonExistentPath = path.join(worktreeBaseDir, 'does-not-exist');

      // Should not throw - just complete successfully
      await lifecycle.removeWorktree(nonExistentPath);
      // If we get here, it didn't throw
      expect(true).toBe(true);
    });

    it('should force remove dirty worktree when requested', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'dirty-worktree');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);
      await lifecycle.createWorktree(worktreePath, 'session/dirty-worktree', baseCommit);

      // Make the worktree dirty
      await fs.writeFile(path.join(worktreePath, 'dirty.txt'), 'uncommitted');

      await lifecycle.removeWorktree(worktreePath, { force: true });

      const exists = await gitExecutor.pathExists(worktreePath);
      expect(exists).toBe(false);
    });
  });

  describe('listWorktrees', () => {
    it('should list all worktrees', async () => {
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);

      // Create two worktrees
      await lifecycle.createWorktree(
        path.join(worktreeBaseDir, 'wt1'),
        'session/wt1',
        baseCommit
      );
      await lifecycle.createWorktree(
        path.join(worktreeBaseDir, 'wt2'),
        'session/wt2',
        baseCommit
      );

      const worktrees = await lifecycle.listWorktrees();

      // Should have main repo + 2 worktrees
      expect(worktrees.length).toBeGreaterThanOrEqual(3);

      const paths = worktrees.map(w => w.path);
      expect(paths).toContain(path.join(worktreeBaseDir, 'wt1'));
      expect(paths).toContain(path.join(worktreeBaseDir, 'wt2'));
    });

    it('should parse worktree info correctly', async () => {
      const worktreePath = path.join(worktreeBaseDir, 'info-test');
      const baseCommit = await gitExecutor.getCurrentCommit(gitRepoDir);
      await lifecycle.createWorktree(worktreePath, 'session/info-test', baseCommit);

      const worktrees = await lifecycle.listWorktrees();
      const wt = worktrees.find(w => w.path === worktreePath);

      expect(wt).toBeDefined();
      expect(wt!.branch).toBe('session/info-test');
      expect(wt!.commit).toBeTruthy();
    });

    it('should return empty array for repo without worktrees', async () => {
      const worktrees = await lifecycle.listWorktrees();

      // Only main worktree
      expect(worktrees.length).toBe(1);
      expect(worktrees[0].path).toBe(gitRepoDir);
    });
  });

  describe('factory function', () => {
    it('should create WorktreeLifecycle instance', () => {
      const lifecycle = createWorktreeLifecycle({
        gitExecutor,
        repoRoot: gitRepoDir,
        worktreeBaseDir,
        branchPrefix: 'session/',
      });
      expect(lifecycle).toBeInstanceOf(WorktreeLifecycle);
    });
  });
});
