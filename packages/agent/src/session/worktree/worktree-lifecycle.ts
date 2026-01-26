/**
 * @fileoverview Worktree Lifecycle
 *
 * Handles worktree CRUD operations: create, remove, list.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import * as fs from 'fs/promises';
import type { GitExecutor } from './git-executor.js';
import type { WorktreeInfo } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for WorktreeLifecycle.
 */
export interface WorktreeLifecycleDeps {
  gitExecutor: GitExecutor;
  repoRoot: string;
  worktreeBaseDir: string;
  branchPrefix: string;
}

/**
 * Options for removing a worktree.
 */
export interface RemoveWorktreeOptions {
  deleteBranch?: boolean;
  force?: boolean;
}

// =============================================================================
// WorktreeLifecycle
// =============================================================================

/**
 * Manages worktree lifecycle operations.
 */
export class WorktreeLifecycle {
  private git: GitExecutor;
  private repoRoot: string;
  private branchPrefix: string;
  /** @internal Base directory for worktrees, stored for potential future use */
  readonly worktreeBaseDir: string;

  constructor(deps: WorktreeLifecycleDeps) {
    this.git = deps.gitExecutor;
    this.repoRoot = deps.repoRoot;
    this.branchPrefix = deps.branchPrefix;
    this.worktreeBaseDir = deps.worktreeBaseDir;
  }

  /**
   * Create a new worktree with a branch.
   */
  async createWorktree(
    worktreePath: string,
    branchName: string,
    baseCommit: string
  ): Promise<void> {
    // Check if branch exists
    const branchExists = await this.git.branchExists(this.repoRoot, branchName);

    if (!branchExists) {
      // Create branch from base commit
      const branchResult = await this.git.execGit(
        ['branch', branchName, baseCommit],
        this.repoRoot
      );
      if (branchResult.exitCode !== 0) {
        throw new Error(`Failed to create branch: ${branchResult.stderr}`);
      }
    }

    // Create worktree
    const result = await this.git.execGit(
      ['worktree', 'add', worktreePath, branchName],
      this.repoRoot
    );

    if (result.exitCode !== 0) {
      throw new Error(`Failed to create worktree: ${result.stderr}`);
    }
  }

  /**
   * Remove a worktree.
   */
  async removeWorktree(
    worktreePath: string,
    options: RemoveWorktreeOptions = {}
  ): Promise<void> {
    // Check if directory exists
    const dirExists = await this.git.pathExists(worktreePath);

    if (!dirExists) {
      // Directory already gone - just prune stale worktree references
      await this.git.execGit(['worktree', 'prune'], this.repoRoot).catch(() => {});
      return;
    }

    // Get branch name before removal (for optional deletion)
    let branchName: string | undefined;
    if (options.deleteBranch) {
      branchName = await this.git.getCurrentBranch(worktreePath);
    }

    // Try git worktree remove
    const forceFlag = options.force ? '--force' : '';
    const args = ['worktree', 'remove', worktreePath];
    if (forceFlag) {
      args.push(forceFlag);
    }

    const result = await this.git.execGit(args, this.repoRoot);

    if (result.exitCode !== 0) {
      // Fallback: remove directory directly and prune
      await fs.rm(worktreePath, { recursive: true, force: true });
      await this.git.execGit(['worktree', 'prune'], this.repoRoot).catch(() => {});
    }

    // Delete branch if requested
    if (options.deleteBranch && branchName && branchName !== 'HEAD') {
      await this.git.execGit(['branch', '-D', branchName], this.repoRoot).catch(() => {});
    }
  }

  /**
   * List all worktrees.
   */
  async listWorktrees(): Promise<WorktreeInfo[]> {
    const result = await this.git.execGit(['worktree', 'list', '--porcelain'], this.repoRoot);

    if (result.exitCode !== 0) {
      return [];
    }

    const worktrees: WorktreeInfo[] = [];
    const blocks = result.stdout.split('\n\n');

    for (const block of blocks) {
      if (!block.trim()) continue;

      const lines = block.split('\n');
      const worktreePath = lines.find(l => l.startsWith('worktree '))?.slice(9);
      const branch = lines.find(l => l.startsWith('branch '))?.slice(7);
      const commitLine = lines.find(l => l.startsWith('HEAD '));
      const commit = commitLine?.slice(5);

      if (worktreePath) {
        const branchName = branch?.replace('refs/heads/', '') || 'HEAD';
        const sessionId = branchName.startsWith(this.branchPrefix)
          ? branchName.replace(this.branchPrefix, '')
          : undefined;

        worktrees.push({
          path: worktreePath,
          branch: branchName,
          commit,
          sessionId,
        });
      }
    }

    return worktrees;
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a WorktreeLifecycle instance.
 */
export function createWorktreeLifecycle(deps: WorktreeLifecycleDeps): WorktreeLifecycle {
  return new WorktreeLifecycle(deps);
}
