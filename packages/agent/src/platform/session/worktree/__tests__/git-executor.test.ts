/**
 * @fileoverview Tests for GitExecutor
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { GitExecutor, createGitExecutor } from '../git-executor.js';

// =============================================================================
// Test Helpers
// =============================================================================

let testDir: string;
let gitRepoDir: string;
let nonGitDir: string;

async function setupTestDirs() {
  const tmpBase = await fs.realpath(os.tmpdir());
  testDir = path.join(tmpBase, `git-executor-test-${Date.now()}`);
  gitRepoDir = path.join(testDir, 'git-repo');
  nonGitDir = path.join(testDir, 'non-git');

  await fs.mkdir(gitRepoDir, { recursive: true });
  await fs.mkdir(nonGitDir, { recursive: true });

  // Initialize git repo
  const { execSync } = await import('child_process');
  execSync('git init', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.name "Test User"', { cwd: gitRepoDir, stdio: 'pipe' });

  // Create initial commit
  await fs.writeFile(path.join(gitRepoDir, 'test.txt'), 'test content');
  execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git commit -m "Initial commit"', { cwd: gitRepoDir, stdio: 'pipe' });
}

async function cleanupTestDirs() {
  if (testDir) {
    await fs.rm(testDir, { recursive: true, force: true });
  }
}

// =============================================================================
// Tests
// =============================================================================

describe('GitExecutor', () => {
  let executor: GitExecutor;

  beforeEach(async () => {
    executor = createGitExecutor();
    await setupTestDirs();
  });

  afterEach(async () => {
    await cleanupTestDirs();
  });

  describe('execGit', () => {
    it('should execute git command successfully', async () => {
      const result = await executor.execGit(['status'], gitRepoDir);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain('On branch');
    });

    it('should return stdout and stderr', async () => {
      const result = await executor.execGit(['log', '--oneline', '-1'], gitRepoDir);

      expect(result.exitCode).toBe(0);
      expect(result.stdout).toContain('Initial commit');
      expect(result.stderr).toBe('');
    });

    it('should handle command failure', async () => {
      const result = await executor.execGit(['checkout', 'nonexistent-branch'], gitRepoDir);

      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toBeTruthy();
    });

    it('should handle invalid git directory', async () => {
      const result = await executor.execGit(['status'], nonGitDir);

      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain('not a git repository');
    });

    it('should respect custom timeout', async () => {
      // This should complete quickly, just testing timeout is passed
      const result = await executor.execGit(['status'], gitRepoDir, { timeout: 5000 });

      expect(result.exitCode).toBe(0);
    });
  });

  describe('pathExists', () => {
    it('should return true for existing path', async () => {
      const result = await executor.pathExists(gitRepoDir);
      expect(result).toBe(true);
    });

    it('should return false for non-existing path', async () => {
      const result = await executor.pathExists(path.join(testDir, 'does-not-exist'));
      expect(result).toBe(false);
    });

    it('should return true for existing file', async () => {
      const result = await executor.pathExists(path.join(gitRepoDir, 'test.txt'));
      expect(result).toBe(true);
    });
  });

  describe('isGitRepo', () => {
    it('should return true for git repository', async () => {
      const result = await executor.isGitRepo(gitRepoDir);
      expect(result).toBe(true);
    });

    it('should return false for non-git directory', async () => {
      const result = await executor.isGitRepo(nonGitDir);
      expect(result).toBe(false);
    });

    it('should return false for non-existing directory', async () => {
      const result = await executor.isGitRepo(path.join(testDir, 'does-not-exist'));
      expect(result).toBe(false);
    });

    it('should return true for subdirectory of git repo', async () => {
      const subDir = path.join(gitRepoDir, 'subdir');
      await fs.mkdir(subDir);

      const result = await executor.isGitRepo(subDir);
      expect(result).toBe(true);
    });
  });

  describe('getRepoRoot', () => {
    it('should return repo root for git directory', async () => {
      const result = await executor.getRepoRoot(gitRepoDir);
      expect(result).toBe(gitRepoDir);
    });

    it('should return null for non-git directory', async () => {
      const result = await executor.getRepoRoot(nonGitDir);
      expect(result).toBeNull();
    });

    it('should return repo root from subdirectory', async () => {
      const subDir = path.join(gitRepoDir, 'subdir');
      await fs.mkdir(subDir);

      const result = await executor.getRepoRoot(subDir);
      expect(result).toBe(gitRepoDir);
    });
  });

  describe('getCurrentBranch', () => {
    it('should return current branch name', async () => {
      const result = await executor.getCurrentBranch(gitRepoDir);

      // Git init creates 'master' or 'main' depending on config
      expect(['master', 'main']).toContain(result);
    });

    it('should return branch name after checkout', async () => {
      const { execSync } = await import('child_process');
      execSync('git checkout -b feature-branch', { cwd: gitRepoDir, stdio: 'pipe' });

      const result = await executor.getCurrentBranch(gitRepoDir);
      expect(result).toBe('feature-branch');
    });

    it('should handle detached HEAD', async () => {
      const { execSync } = await import('child_process');
      const commitHash = execSync('git rev-parse HEAD', { cwd: gitRepoDir }).toString().trim();
      execSync(`git checkout ${commitHash}`, { cwd: gitRepoDir, stdio: 'pipe' });

      const result = await executor.getCurrentBranch(gitRepoDir);
      expect(result).toBe('HEAD');
    });
  });

  describe('getCurrentCommit', () => {
    it('should return current commit hash', async () => {
      const result = await executor.getCurrentCommit(gitRepoDir);

      expect(result).toMatch(/^[a-f0-9]{40}$/);
    });

    it('should return different hash after new commit', async () => {
      const firstCommit = await executor.getCurrentCommit(gitRepoDir);

      const { execSync } = await import('child_process');
      await fs.writeFile(path.join(gitRepoDir, 'new-file.txt'), 'new content');
      execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
      execSync('git commit -m "Second commit"', { cwd: gitRepoDir, stdio: 'pipe' });

      const secondCommit = await executor.getCurrentCommit(gitRepoDir);

      expect(secondCommit).not.toBe(firstCommit);
      expect(secondCommit).toMatch(/^[a-f0-9]{40}$/);
    });
  });

  describe('branchExists', () => {
    it('should return true for existing branch', async () => {
      const currentBranch = await executor.getCurrentBranch(gitRepoDir);
      const result = await executor.branchExists(gitRepoDir, currentBranch);

      expect(result).toBe(true);
    });

    it('should return false for non-existing branch', async () => {
      const result = await executor.branchExists(gitRepoDir, 'nonexistent-branch');

      expect(result).toBe(false);
    });

    it('should return true for newly created branch', async () => {
      const { execSync } = await import('child_process');
      execSync('git branch new-branch', { cwd: gitRepoDir, stdio: 'pipe' });

      const result = await executor.branchExists(gitRepoDir, 'new-branch');
      expect(result).toBe(true);
    });
  });

  describe('hasUncommittedChanges', () => {
    it('should return false for clean worktree', async () => {
      const result = await executor.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(false);
    });

    it('should return true for modified file', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'test.txt'), 'modified content');

      const result = await executor.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(true);
    });

    it('should return true for new untracked file', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'untracked.txt'), 'new content');

      const result = await executor.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(true);
    });

    it('should return true for staged changes', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'staged.txt'), 'staged content');
      const { execSync } = await import('child_process');
      execSync('git add staged.txt', { cwd: gitRepoDir, stdio: 'pipe' });

      const result = await executor.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(true);
    });
  });

  describe('factory function', () => {
    it('should create GitExecutor instance', () => {
      const executor = createGitExecutor();
      expect(executor).toBeInstanceOf(GitExecutor);
    });

    it('should accept custom timeout', () => {
      const executor = createGitExecutor(5000);
      expect(executor).toBeInstanceOf(GitExecutor);
    });
  });
});
