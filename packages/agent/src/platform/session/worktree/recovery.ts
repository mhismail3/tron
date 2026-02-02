/**
 * @fileoverview Worktree Recovery
 *
 * Handles recovery of orphaned worktrees from crashed sessions.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type { GitExecutor } from './git-executor.js';

const logger = createLogger('worktree-recovery');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for WorktreeRecovery.
 */
export interface WorktreeRecoveryDeps {
  gitExecutor: GitExecutor;
  repoRoot: string;
  worktreeBaseDir: string;
  /** Check if a session is currently active */
  isSessionActive: (sessionId: string) => boolean;
  /** Whether to delete worktrees after recovery */
  deleteOnRecovery: boolean;
}

/**
 * Result of recovery operation for a single worktree.
 */
export interface RecoveryResult {
  sessionId: string;
  path: string;
  hadChanges: boolean;
  committed: boolean;
  deleted: boolean;
  error?: string;
}

// =============================================================================
// WorktreeRecovery
// =============================================================================

/**
 * Handles recovery of orphaned worktrees.
 *
 * An orphaned worktree is one that:
 * - Exists in the worktree base directory
 * - Has no active session associated with it
 *
 * Recovery involves:
 * - Committing any uncommitted changes
 * - Optionally removing the worktree
 */
export class WorktreeRecovery {
  private git: GitExecutor;
  private repoRoot: string;
  private worktreeBaseDir: string;
  private isSessionActive: (sessionId: string) => boolean;
  private deleteOnRecovery: boolean;

  constructor(deps: WorktreeRecoveryDeps) {
    this.git = deps.gitExecutor;
    this.repoRoot = deps.repoRoot;
    this.worktreeBaseDir = deps.worktreeBaseDir;
    this.isSessionActive = deps.isSessionActive;
    this.deleteOnRecovery = deps.deleteOnRecovery;
  }

  /**
   * Recover all orphaned worktrees.
   */
  async recoverOrphaned(): Promise<RecoveryResult[]> {
    const results: RecoveryResult[] = [];

    // Check if worktree base directory exists
    if (!await this.git.pathExists(this.worktreeBaseDir)) {
      return results;
    }

    try {
      const entries = await fs.readdir(this.worktreeBaseDir, { withFileTypes: true });

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const sessionId = entry.name;
        const worktreePath = path.join(this.worktreeBaseDir, sessionId);

        // Skip active sessions
        if (this.isSessionActive(sessionId)) {
          continue;
        }

        // Verify directory still exists
        if (!await this.git.pathExists(worktreePath)) {
          logger.debug('Orphaned worktree directory no longer exists', {
            sessionId,
            path: worktreePath,
          });
          continue;
        }

        logger.info('Found orphaned worktree', { sessionId, path: worktreePath });

        const result = await this.recoverSingle(sessionId, worktreePath);
        results.push(result);
      }

      // Prune stale worktree references
      await this.pruneStale();
    } catch (error) {
      const structured = categorizeError(error, { operation: 'scan-orphaned' });
      logger.warn('Failed to scan for orphaned worktrees', {
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
      });
    }

    return results;
  }

  /**
   * Recover a single orphaned worktree.
   */
  async recoverSingle(sessionId: string, worktreePath: string): Promise<RecoveryResult> {
    const result: RecoveryResult = {
      sessionId,
      path: worktreePath,
      hadChanges: false,
      committed: false,
      deleted: false,
    };

    try {
      // Check for uncommitted changes
      const statusResult = await this.git.execGit(['status', '--porcelain'], worktreePath);
      result.hadChanges = !!statusResult.stdout.trim();

      if (result.hadChanges) {
        // Commit changes
        await this.git.execGit(['add', '-A'], worktreePath);
        const commitResult = await this.git.execGit(
          ['commit', '-m', `[RECOVERED] Session ${sessionId}`],
          worktreePath
        );
        result.committed = commitResult.exitCode === 0;

        if (result.committed) {
          logger.info('Committed orphaned changes', { sessionId });
        }
      }

      // Remove worktree if configured
      if (this.deleteOnRecovery) {
        await this.removeWorktree(worktreePath);
        result.deleted = true;
        logger.info('Removed orphaned worktree', { sessionId });
      }
    } catch (error) {
      const structured = categorizeError(error, {
        sessionId,
        path: worktreePath,
        operation: 'recover',
      });
      result.error = structured.message;
      logger.warn('Failed to recover orphaned worktree', {
        sessionId,
        path: worktreePath,
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
      });
    }

    return result;
  }

  /**
   * Remove a worktree directory.
   */
  private async removeWorktree(worktreePath: string): Promise<void> {
    const result = await this.git.execGit(
      ['worktree', 'remove', worktreePath, '--force'],
      this.repoRoot
    );

    if (result.exitCode !== 0) {
      // Fallback: remove directory directly
      await fs.rm(worktreePath, { recursive: true, force: true });
    }
  }

  /**
   * Prune stale worktree references.
   */
  async pruneStale(): Promise<void> {
    try {
      await this.git.execGit(['worktree', 'prune'], this.repoRoot);
    } catch {
      // Ignore prune errors
    }
  }

  /**
   * Check if there are any orphaned worktrees.
   */
  async hasOrphaned(): Promise<boolean> {
    if (!await this.git.pathExists(this.worktreeBaseDir)) {
      return false;
    }

    try {
      const entries = await fs.readdir(this.worktreeBaseDir, { withFileTypes: true });

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const sessionId = entry.name;
        const worktreePath = path.join(this.worktreeBaseDir, sessionId);

        if (!this.isSessionActive(sessionId) && await this.git.pathExists(worktreePath)) {
          return true;
        }
      }
    } catch {
      return false;
    }

    return false;
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a WorktreeRecovery instance.
 */
export function createWorktreeRecovery(deps: WorktreeRecoveryDeps): WorktreeRecovery {
  return new WorktreeRecovery(deps);
}
