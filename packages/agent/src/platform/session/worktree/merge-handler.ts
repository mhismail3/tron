/**
 * @fileoverview Merge Handler
 *
 * Handles merge operations: merge, rebase, squash.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import type { GitExecutor } from './git-executor.js';
import type { MergeResult, MergeOptions } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for MergeHandler.
 */
export interface MergeHandlerDeps {
  gitExecutor: GitExecutor;
}

// =============================================================================
// MergeHandler
// =============================================================================

/**
 * Handles git merge operations.
 */
export class MergeHandler {
  private git: GitExecutor;

  constructor(deps: MergeHandlerDeps) {
    this.git = deps.gitExecutor;
  }

  /**
   * Check if there are uncommitted changes.
   */
  async hasUncommittedChanges(worktreePath: string): Promise<boolean> {
    return this.git.hasUncommittedChanges(worktreePath);
  }

  /**
   * Commit all changes (staged and unstaged).
   * Returns the commit hash, or null if nothing to commit.
   */
  async commitChanges(worktreePath: string, message: string): Promise<string | null> {
    // Check if there are changes
    const hasChanges = await this.hasUncommittedChanges(worktreePath);
    if (!hasChanges) {
      return null;
    }

    // Stage all changes
    await this.git.execGit(['add', '-A'], worktreePath);

    // Commit
    const result = await this.git.execGit(
      ['commit', '-m', message],
      worktreePath
    );

    if (result.exitCode !== 0) {
      return null;
    }

    // Get commit hash
    return this.git.getCurrentCommit(worktreePath);
  }

  /**
   * Perform a git merge.
   */
  async merge(worktreePath: string, sourceBranch: string): Promise<MergeResult> {
    const result = await this.git.execGit(
      ['merge', '--no-ff', '-m', `Merge branch '${sourceBranch}'`, sourceBranch],
      worktreePath
    );

    if (result.exitCode !== 0) {
      // Check for conflicts
      const statusResult = await this.git.execGit(['status', '--porcelain'], worktreePath);
      const conflicts = statusResult.stdout
        .split('\n')
        .filter(line => line.startsWith('UU') || line.startsWith('AA') || line.startsWith('DD'))
        .map(line => line.slice(3));

      // Abort the merge
      await this.git.execGit(['merge', '--abort'], worktreePath).catch(() => {});

      return {
        success: false,
        strategy: 'merge',
        conflicts: conflicts.length > 0 ? conflicts : [result.stderr || 'Merge failed'],
      };
    }

    const commitHash = await this.git.getCurrentCommit(worktreePath);

    return {
      success: true,
      strategy: 'merge',
      commitHash,
    };
  }

  /**
   * Perform a git rebase.
   */
  async rebase(worktreePath: string, targetBranch: string): Promise<MergeResult> {
    const result = await this.git.execGit(
      ['rebase', targetBranch],
      worktreePath
    );

    if (result.exitCode !== 0) {
      // Abort the rebase
      await this.git.execGit(['rebase', '--abort'], worktreePath).catch(() => {});

      return {
        success: false,
        strategy: 'rebase',
        error: result.stderr || 'Rebase failed',
      };
    }

    const commitHash = await this.git.getCurrentCommit(worktreePath);

    return {
      success: true,
      strategy: 'rebase',
      commitHash,
    };
  }

  /**
   * Perform a squash merge.
   */
  async squash(
    worktreePath: string,
    sourceBranch: string,
    commitMessage: string
  ): Promise<MergeResult> {
    // Squash merge
    const squashResult = await this.git.execGit(
      ['merge', '--squash', sourceBranch],
      worktreePath
    );

    if (squashResult.exitCode !== 0) {
      return {
        success: false,
        strategy: 'squash',
        error: squashResult.stderr || 'Squash merge failed',
      };
    }

    // Check if there's anything to commit
    const hasChanges = await this.hasUncommittedChanges(worktreePath);
    if (!hasChanges) {
      // Nothing to squash - already up to date
      return {
        success: true,
        strategy: 'squash',
        commitHash: await this.git.getCurrentCommit(worktreePath),
      };
    }

    // Commit the squash
    const commitResult = await this.git.execGit(
      ['commit', '-m', commitMessage],
      worktreePath
    );

    if (commitResult.exitCode !== 0) {
      return {
        success: false,
        strategy: 'squash',
        error: commitResult.stderr || 'Commit failed',
      };
    }

    const commitHash = await this.git.getCurrentCommit(worktreePath);

    return {
      success: true,
      strategy: 'squash',
      commitHash,
    };
  }

  /**
   * Merge a session using the specified strategy.
   */
  async mergeSession(
    worktreePath: string,
    sourceBranch: string,
    options: MergeOptions
  ): Promise<MergeResult> {
    switch (options.strategy) {
      case 'merge':
        return this.merge(worktreePath, sourceBranch);

      case 'rebase':
        return this.rebase(worktreePath, sourceBranch);

      case 'squash':
        return this.squash(
          worktreePath,
          sourceBranch,
          options.commitMessage || `Squash merge ${sourceBranch}`
        );

      default:
        return {
          success: false,
          strategy: options.strategy,
          error: `Unknown merge strategy: ${options.strategy}`,
        };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a MergeHandler instance.
 */
export function createMergeHandler(deps: MergeHandlerDeps): MergeHandler {
  return new MergeHandler(deps);
}
