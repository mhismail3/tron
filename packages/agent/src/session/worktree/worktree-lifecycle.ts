/**
 * @fileoverview Worktree Lifecycle
 *
 * Handles worktree CRUD operations: create, remove, list.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import * as fs from 'fs/promises';
import type { GitExecutor } from './git-executor.js';
import type { WorktreeInfo } from './types.js';
import { createLogger, createOperationLogger } from '../../logging/index.js';

const logger = createLogger('worktree:lifecycle');

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
    const op = createOperationLogger(logger, 'worktree.create', {
      context: { worktreePath, branchName, baseCommit },
    });

    op.trace('Starting worktree creation');

    // Check if branch exists
    const branchExists = await this.git.branchExists(this.repoRoot, branchName);
    op.debug('Branch existence check', { branchExists });

    if (!branchExists) {
      op.debug('Creating new branch from base commit');
      // Create branch from base commit
      const branchResult = await this.git.execGit(
        ['branch', branchName, baseCommit],
        this.repoRoot
      );
      if (branchResult.exitCode !== 0) {
        op.error('Failed to create branch', { stderr: branchResult.stderr });
        throw new Error(`Failed to create branch: ${branchResult.stderr}`);
      }
      op.debug('Branch created successfully');
    }

    // Create worktree
    op.trace('Creating worktree');
    const result = await this.git.execGit(
      ['worktree', 'add', worktreePath, branchName],
      this.repoRoot
    );

    if (result.exitCode !== 0) {
      op.error('Failed to create worktree', { stderr: result.stderr });
      throw new Error(`Failed to create worktree: ${result.stderr}`);
    }

    op.complete('Worktree created successfully');
  }

  /**
   * Remove a worktree.
   */
  async removeWorktree(
    worktreePath: string,
    options: RemoveWorktreeOptions = {}
  ): Promise<void> {
    const op = createOperationLogger(logger, 'worktree.remove', {
      context: { worktreePath, ...options },
    });

    op.trace('Starting worktree removal');

    // Check if directory exists
    const dirExists = await this.git.pathExists(worktreePath);
    op.debug('Directory existence check', { dirExists });

    if (!dirExists) {
      // Directory already gone - just prune stale worktree references
      op.debug('Directory does not exist, pruning stale references');
      await this.git.execGit(['worktree', 'prune'], this.repoRoot).catch((err) => {
        op.warn('Worktree prune failed (non-critical)', {
          error: err instanceof Error ? err.message : String(err),
        });
      });
      op.complete('Worktree removal completed (directory was already gone)');
      return;
    }

    // Get branch name before removal (for optional deletion)
    let branchName: string | undefined;
    if (options.deleteBranch) {
      branchName = await this.git.getCurrentBranch(worktreePath);
      op.debug('Retrieved branch name for deletion', { branchName });
    }

    // Try git worktree remove
    const forceFlag = options.force ? '--force' : '';
    const args = ['worktree', 'remove', worktreePath];
    if (forceFlag) {
      args.push(forceFlag);
    }

    op.trace('Executing git worktree remove');
    const result = await this.git.execGit(args, this.repoRoot);

    if (result.exitCode !== 0) {
      // Fallback: remove directory directly and prune
      op.warn('Git worktree remove failed, using fallback', {
        exitCode: result.exitCode,
        stderr: result.stderr,
      });
      await fs.rm(worktreePath, { recursive: true, force: true });
      op.debug('Directory removed directly');

      await this.git.execGit(['worktree', 'prune'], this.repoRoot).catch((err) => {
        op.warn('Worktree prune failed after fallback (non-critical)', {
          error: err instanceof Error ? err.message : String(err),
        });
      });
    }

    // Delete branch if requested
    if (options.deleteBranch && branchName && branchName !== 'HEAD') {
      op.debug('Deleting branch', { branchName });
      await this.git.execGit(['branch', '-D', branchName], this.repoRoot).catch((err) => {
        op.warn('Branch deletion failed (non-critical)', {
          branchName,
          error: err instanceof Error ? err.message : String(err),
        });
      });
    }

    op.complete('Worktree removal completed');
  }

  /**
   * List all worktrees.
   */
  async listWorktrees(): Promise<WorktreeInfo[]> {
    const op = createOperationLogger(logger, 'worktree.list', {});

    op.trace('Listing worktrees');

    const result = await this.git.execGit(['worktree', 'list', '--porcelain'], this.repoRoot);

    if (result.exitCode !== 0) {
      op.warn('Failed to list worktrees', {
        exitCode: result.exitCode,
        stderr: result.stderr,
      });
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

    op.debug('Worktrees found', { count: worktrees.length });
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
