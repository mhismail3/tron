/**
 * @fileoverview Tests for MergeHandler
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { MergeHandler, createMergeHandler } from '../merge-handler.js';
import { GitExecutor, createGitExecutor } from '../git-executor.js';

// =============================================================================
// Test Helpers
// =============================================================================

let testDir: string;
let gitRepoDir: string;
let gitExecutor: GitExecutor;

async function setupTestRepo() {
  const tmpBase = await fs.realpath(os.tmpdir());
  testDir = path.join(tmpBase, `merge-handler-test-${Date.now()}`);
  gitRepoDir = path.join(testDir, 'git-repo');

  await fs.mkdir(gitRepoDir, { recursive: true });

  const { execSync } = await import('child_process');
  execSync('git init', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git config user.name "Test User"', { cwd: gitRepoDir, stdio: 'pipe' });

  // Create initial commit on main
  await fs.writeFile(path.join(gitRepoDir, 'main.txt'), 'main content');
  execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync('git commit -m "Initial commit"', { cwd: gitRepoDir, stdio: 'pipe' });

  gitExecutor = createGitExecutor();
}

async function createFeatureBranch(branchName: string, filename: string, content: string) {
  const { execSync } = await import('child_process');
  execSync(`git checkout -b ${branchName}`, { cwd: gitRepoDir, stdio: 'pipe' });
  await fs.writeFile(path.join(gitRepoDir, filename), content);
  execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
  execSync(`git commit -m "Add ${filename}"`, { cwd: gitRepoDir, stdio: 'pipe' });
}

async function checkoutBranch(branchName: string) {
  const { execSync } = await import('child_process');
  execSync(`git checkout ${branchName}`, { cwd: gitRepoDir, stdio: 'pipe' });
}

async function getMainBranch(): Promise<string> {
  const result = await gitExecutor.execGit(['branch', '--list', 'main', 'master'], gitRepoDir);
  return result.stdout.includes('main') ? 'main' : 'master';
}

async function cleanupTestDirs() {
  if (testDir) {
    await fs.rm(testDir, { recursive: true, force: true });
  }
}

// =============================================================================
// Tests
// =============================================================================

describe('MergeHandler', () => {
  let handler: MergeHandler;
  let mainBranch: string;

  beforeEach(async () => {
    await setupTestRepo();
    handler = createMergeHandler({ gitExecutor });
    mainBranch = await getMainBranch();
  });

  afterEach(async () => {
    await cleanupTestDirs();
  });

  describe('hasUncommittedChanges', () => {
    it('should return false for clean worktree', async () => {
      const result = await handler.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(false);
    });

    it('should return true for modified file', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'main.txt'), 'modified');
      const result = await handler.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(true);
    });

    it('should return true for new untracked file', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'new.txt'), 'new');
      const result = await handler.hasUncommittedChanges(gitRepoDir);
      expect(result).toBe(true);
    });
  });

  describe('commitChanges', () => {
    it('should commit all changes', async () => {
      await fs.writeFile(path.join(gitRepoDir, 'new.txt'), 'new content');

      const hash = await handler.commitChanges(gitRepoDir, 'Test commit');

      expect(hash).toBeTruthy();
      expect(hash).toMatch(/^[a-f0-9]{40}$/);

      // Verify commit message
      const logResult = await gitExecutor.execGit(['log', '-1', '--pretty=%s'], gitRepoDir);
      expect(logResult.stdout).toBe('Test commit');
    });

    it('should return null for nothing to commit', async () => {
      const hash = await handler.commitChanges(gitRepoDir, 'Empty commit');
      expect(hash).toBeNull();
    });

    it('should commit staged and unstaged changes', async () => {
      // Create staged change
      await fs.writeFile(path.join(gitRepoDir, 'staged.txt'), 'staged');
      const { execSync } = await import('child_process');
      execSync('git add staged.txt', { cwd: gitRepoDir, stdio: 'pipe' });

      // Create unstaged change
      await fs.writeFile(path.join(gitRepoDir, 'unstaged.txt'), 'unstaged');

      const hash = await handler.commitChanges(gitRepoDir, 'Commit all');

      expect(hash).toBeTruthy();

      // Both files should be committed
      const files = await fs.readdir(gitRepoDir);
      expect(files).toContain('staged.txt');
      expect(files).toContain('unstaged.txt');

      // Should be clean now
      const hasChanges = await handler.hasUncommittedChanges(gitRepoDir);
      expect(hasChanges).toBe(false);
    });
  });

  describe('merge', () => {
    it('should perform git merge', async () => {
      await createFeatureBranch('feature-merge', 'feature.txt', 'feature content');
      await checkoutBranch(mainBranch);

      const result = await handler.merge(gitRepoDir, 'feature-merge');

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('merge');
      expect(result.commitHash).toBeTruthy();

      // Verify file exists after merge
      const hasFile = await gitExecutor.pathExists(path.join(gitRepoDir, 'feature.txt'));
      expect(hasFile).toBe(true);
    });

    it('should handle merge conflicts', async () => {
      // Create conflicting changes
      await createFeatureBranch('conflict-branch', 'main.txt', 'conflict content');
      await checkoutBranch(mainBranch);
      await fs.writeFile(path.join(gitRepoDir, 'main.txt'), 'different content');
      const { execSync } = await import('child_process');
      execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
      execSync('git commit -m "Main change"', { cwd: gitRepoDir, stdio: 'pipe' });

      const result = await handler.merge(gitRepoDir, 'conflict-branch');

      expect(result.success).toBe(false);
      expect(result.conflicts).toBeDefined();
      expect(result.conflicts!.length).toBeGreaterThan(0);
    });
  });

  describe('rebase', () => {
    it('should perform git rebase', async () => {
      await createFeatureBranch('feature-rebase', 'rebase.txt', 'rebase content');

      const result = await handler.rebase(gitRepoDir, mainBranch);

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('rebase');
    });

    it('should handle rebase conflicts', async () => {
      // Create conflicting changes
      await createFeatureBranch('rebase-conflict', 'main.txt', 'rebase conflict');
      await checkoutBranch(mainBranch);
      await fs.writeFile(path.join(gitRepoDir, 'main.txt'), 'main conflict');
      const { execSync } = await import('child_process');
      execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
      execSync('git commit -m "Main change for rebase"', { cwd: gitRepoDir, stdio: 'pipe' });
      await checkoutBranch('rebase-conflict');

      const result = await handler.rebase(gitRepoDir, mainBranch);

      expect(result.success).toBe(false);
      expect(result.error).toBeDefined();
    });
  });

  describe('squash', () => {
    it('should squash commits into one', async () => {
      // Create branch with multiple commits
      await createFeatureBranch('feature-squash', 'squash1.txt', 'content 1');
      await fs.writeFile(path.join(gitRepoDir, 'squash2.txt'), 'content 2');
      const { execSync } = await import('child_process');
      execSync('git add .', { cwd: gitRepoDir, stdio: 'pipe' });
      execSync('git commit -m "Second commit"', { cwd: gitRepoDir, stdio: 'pipe' });

      await checkoutBranch(mainBranch);

      const result = await handler.squash(gitRepoDir, 'feature-squash', 'Squashed commit');

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('squash');
      expect(result.commitHash).toBeTruthy();

      // Verify files exist
      const hasFile1 = await gitExecutor.pathExists(path.join(gitRepoDir, 'squash1.txt'));
      const hasFile2 = await gitExecutor.pathExists(path.join(gitRepoDir, 'squash2.txt'));
      expect(hasFile1).toBe(true);
      expect(hasFile2).toBe(true);

      // Verify commit message
      const logResult = await gitExecutor.execGit(['log', '-1', '--pretty=%s'], gitRepoDir);
      expect(logResult.stdout).toBe('Squashed commit');
    });

    it('should handle nothing to squash', async () => {
      // Try to squash when already up to date
      const result = await handler.squash(gitRepoDir, mainBranch, 'Nothing to squash');

      // Should handle gracefully
      expect(result.success).toBe(true);
    });
  });

  describe('mergeSession', () => {
    it('should use merge strategy by default', async () => {
      await createFeatureBranch('session-merge', 'session.txt', 'session content');
      await checkoutBranch(mainBranch);

      const result = await handler.mergeSession(gitRepoDir, 'session-merge', {
        strategy: 'merge',
      });

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('merge');
    });

    it('should use squash strategy when specified', async () => {
      await createFeatureBranch('session-squash', 'session-sq.txt', 'squash content');
      await checkoutBranch(mainBranch);

      const result = await handler.mergeSession(gitRepoDir, 'session-squash', {
        strategy: 'squash',
        commitMessage: 'Squash session',
      });

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('squash');
    });

    it('should use rebase strategy when specified', async () => {
      await createFeatureBranch('session-rebase', 'session-rb.txt', 'rebase content');

      const result = await handler.mergeSession(gitRepoDir, mainBranch, {
        strategy: 'rebase',
      });

      expect(result.success).toBe(true);
      expect(result.strategy).toBe('rebase');
    });
  });

  describe('factory function', () => {
    it('should create MergeHandler instance', () => {
      const handler = createMergeHandler({ gitExecutor });
      expect(handler).toBeInstanceOf(MergeHandler);
    });
  });
});
