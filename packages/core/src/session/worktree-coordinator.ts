/**
 * @fileoverview Worktree Coordinator
 *
 * Orchestrates the relationship between sessions and git worktrees.
 * Provides isolated working directories for parallel agent execution.
 *
 * Key responsibilities:
 * 1. Track active sessions and their working directories
 * 2. Detect when isolation is needed (parallel sessions, forks)
 * 3. Create/manage git worktrees for isolated sessions
 * 4. Emit worktree events to the event store
 * 5. Handle cleanup and recovery
 *
 * Design principles:
 * - Event store is source of truth for session state
 * - Lazy isolation: only create worktrees when needed
 * - Graceful degradation: work without git if necessary
 */

import { spawn } from 'child_process';
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../logging/index.js';
import { WorkingDirectory, createWorkingDirectory } from './working-directory.js';
import type { WorkingDirectoryInfo } from './working-directory.js';
import type { EventStore } from '../events/event-store.js';
import type { SessionId, WorktreeAcquiredEvent, WorktreeReleasedEvent, WorktreeCommitEvent, WorktreeMergedEvent } from '../events/types.js';

const logger = createLogger('worktree-coordinator');

// =============================================================================
// Types
// =============================================================================

export interface WorktreeCoordinatorConfig {
  /** Base directory for worktrees (default: .worktrees in repo root) */
  worktreeBaseDir?: string;
  /** Git branch prefix for session branches (default: 'session/') */
  branchPrefix?: string;
  /** Isolation mode */
  isolationMode?: 'lazy' | 'always' | 'never';
  /** Auto-commit uncommitted changes when session ends */
  autoCommitOnRelease?: boolean;
  /** Preserve branches after worktree removal */
  preserveBranches?: boolean;
  /** Delete worktree directory after release */
  deleteWorktreeOnRelease?: boolean;
}

export interface AcquireOptions {
  /** Force isolation even if not needed */
  forceIsolation?: boolean;
  /** Parent session for fork operations */
  parentSessionId?: SessionId;
  /** Parent's commit to branch from */
  parentCommit?: string;
  /** Custom branch name */
  branchName?: string;
}

export interface ReleaseOptions {
  /** Commit message for uncommitted changes */
  commitMessage?: string;
  /** Target branch to merge into */
  mergeTo?: string;
  /** Merge strategy */
  mergeStrategy?: 'merge' | 'rebase' | 'squash';
  /** Force delete even if dirty */
  force?: boolean;
}

interface ActiveSession {
  sessionId: SessionId;
  workingDirectory: WorkingDirectory;
  acquiredAt: Date;
}

// =============================================================================
// Git Helpers
// =============================================================================

/**
 * Check if a path exists on the filesystem
 */
async function pathExists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

async function execGit(
  args: string[],
  cwd: string,
  options?: { timeout?: number }
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return new Promise((resolve, reject) => {
    const timeout = options?.timeout ?? 30000;
    const proc = spawn('git', args, { cwd, timeout });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data: Buffer) => {
      stdout += data.toString();
    });

    proc.stderr.on('data', (data: Buffer) => {
      stderr += data.toString();
    });

    proc.on('close', (code) => {
      resolve({ stdout: stdout.trim(), stderr: stderr.trim(), exitCode: code ?? 0 });
    });

    proc.on('error', (error) => {
      reject(error);
    });
  });
}

// =============================================================================
// WorktreeCoordinator Class
// =============================================================================

/**
 * Coordinates working directories for parallel session execution.
 *
 * The coordinator ensures that:
 * - Single sessions use the main directory (no overhead)
 * - Parallel sessions get isolated worktrees
 * - Forked sessions branch from their parent's commit
 * - All worktree operations are logged as events
 */
export class WorktreeCoordinator {
  private config: Required<WorktreeCoordinatorConfig>;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private mainDirectoryOwner: string | null = null;
  private repoRoot: string | null = null;

  constructor(
    private eventStore: EventStore,
    config: WorktreeCoordinatorConfig = {}
  ) {
    this.config = {
      worktreeBaseDir: '',
      branchPrefix: 'session/',
      isolationMode: 'lazy',
      autoCommitOnRelease: true,
      preserveBranches: true,
      deleteWorktreeOnRelease: true,
      ...config,
    };
  }

  // ===========================================================================
  // Repository Detection
  // ===========================================================================

  /**
   * Check if a directory is inside a git repository
   */
  async isGitRepo(dir: string): Promise<boolean> {
    try {
      const result = await execGit(['rev-parse', '--git-dir'], dir);
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }

  /**
   * Get the root directory of the git repository
   */
  async getRepoRoot(dir: string): Promise<string | null> {
    try {
      const result = await execGit(['rev-parse', '--show-toplevel'], dir);
      return result.exitCode === 0 ? result.stdout : null;
    } catch {
      return null;
    }
  }

  /**
   * Get current branch name
   */
  async getCurrentBranch(dir: string): Promise<string> {
    const result = await execGit(['rev-parse', '--abbrev-ref', 'HEAD'], dir);
    return result.stdout || 'main';
  }

  /**
   * Get current commit hash
   */
  async getCurrentCommit(dir: string): Promise<string> {
    const result = await execGit(['rev-parse', 'HEAD'], dir);
    return result.stdout;
  }

  // ===========================================================================
  // Core Operations
  // ===========================================================================

  /**
   * Acquire a working directory for a session.
   *
   * This is the main entry point. It decides whether to:
   * - Use the main directory (if no other session is active)
   * - Create an isolated worktree (if parallel or forked)
   */
  async acquire(
    sessionId: SessionId,
    workingDir: string,
    options: AcquireOptions = {}
  ): Promise<WorkingDirectory> {
    logger.info('Acquiring working directory', {
      sessionId,
      workingDir,
      forceIsolation: options.forceIsolation,
      parentSessionId: options.parentSessionId,
    });

    // Check if session already has a working directory
    const existing = this.activeSessions.get(sessionId as string);
    if (existing) {
      logger.debug('Session already has working directory', { sessionId });
      return existing.workingDirectory;
    }

    // Determine repo root
    this.repoRoot = await this.getRepoRoot(workingDir);
    if (!this.repoRoot) {
      // Not a git repo - just use the directory as-is
      logger.warn('Not a git repository, using directory without isolation', { workingDir });
      return this.acquireNonGitDirectory(sessionId, workingDir);
    }

    // Determine if we need isolation
    const needsIsolation = this.shouldIsolate(sessionId, options);

    if (needsIsolation) {
      return this.acquireIsolatedWorktree(sessionId, options);
    } else {
      return this.acquireMainDirectory(sessionId);
    }
  }

  /**
   * Release a session's working directory.
   *
   * This handles:
   * - Committing uncommitted changes (if configured)
   * - Merging to target branch (if requested)
   * - Cleaning up the worktree (if isolated)
   */
  async release(
    sessionId: SessionId,
    options: ReleaseOptions = {}
  ): Promise<void> {
    const session = this.activeSessions.get(sessionId as string);
    if (!session) {
      logger.warn('Session not found for release', { sessionId });
      return;
    }

    const workingDir = session.workingDirectory;
    logger.info('Releasing working directory', {
      sessionId,
      path: workingDir.path,
      isolated: workingDir.isolated,
    });

    let finalCommit: string | undefined;

    // Check if the working directory still exists
    const dirExists = await pathExists(workingDir.path);
    if (!dirExists) {
      logger.warn('Working directory no longer exists, cleaning up session state only', {
        sessionId,
        path: workingDir.path,
      });

      // Directory already gone - just clean up internal state
      this.activeSessions.delete(sessionId as string);
      if (this.mainDirectoryOwner === (sessionId as string)) {
        this.mainDirectoryOwner = null;
      }

      // Emit release event indicating directory was already deleted
      await this.emitReleasedEvent(sessionId, {
        finalCommit: undefined,
        deleted: true,
        branchPreserved: this.config.preserveBranches,
      });

      // Prune any stale worktree references if we have a repo root
      if (this.repoRoot && await pathExists(this.repoRoot)) {
        try {
          await execGit(['worktree', 'prune'], this.repoRoot);
        } catch {
          // Ignore prune errors
        }
      }

      return;
    }

    try {
      // Auto-commit if configured and there are changes
      if (this.config.autoCommitOnRelease || options.commitMessage) {
        const hasChanges = await workingDir.hasUncommittedChanges();
        if (hasChanges) {
          const message = options.commitMessage || `Session ${sessionId} auto-save`;
          const result = await workingDir.commit(message, { addAll: true });
          if (result) {
            finalCommit = result.hash;

            // Emit commit event
            await this.emitCommitEvent(sessionId, {
              commitHash: result.hash,
              message,
              filesChanged: result.filesChanged,
              insertions: result.insertions,
              deletions: result.deletions,
            });
          }
        }
      }

      // Merge if requested
      if (options.mergeTo && workingDir.isolated) {
        await this.mergeSession(sessionId, options.mergeTo, options.mergeStrategy || 'merge');
      }

      // Clean up worktree if isolated
      if (workingDir.isolated && this.config.deleteWorktreeOnRelease) {
        await this.removeWorktree(workingDir.path);
      }

      // If this was the main directory owner, release it
      if (this.mainDirectoryOwner === (sessionId as string)) {
        this.mainDirectoryOwner = null;
      }

      // Emit release event
      await this.emitReleasedEvent(sessionId, {
        finalCommit,
        deleted: workingDir.isolated && this.config.deleteWorktreeOnRelease,
        branchPreserved: this.config.preserveBranches,
      });

      // Remove from active sessions
      this.activeSessions.delete(sessionId as string);

      logger.info('Working directory released', {
        sessionId,
        finalCommit,
        isolated: workingDir.isolated,
      });
    } catch (error) {
      logger.error('Failed to release working directory', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });

      // Still remove from active sessions on error
      this.activeSessions.delete(sessionId as string);
      if (this.mainDirectoryOwner === (sessionId as string)) {
        this.mainDirectoryOwner = null;
      }

      throw error;
    }
  }

  /**
   * Get the working directory for a session
   */
  getWorkingDirectory(sessionId: SessionId): WorkingDirectory | null {
    const session = this.activeSessions.get(sessionId as string);
    return session?.workingDirectory ?? null;
  }

  /**
   * Get all active sessions
   */
  getActiveSessions(): Map<string, ActiveSession> {
    return new Map(this.activeSessions);
  }

  /**
   * Check if a session is active
   */
  isSessionActive(sessionId: SessionId): boolean {
    return this.activeSessions.has(sessionId as string);
  }

  // ===========================================================================
  // Isolation Decision
  // ===========================================================================

  /**
   * Determine if a session needs an isolated worktree
   */
  private shouldIsolate(sessionId: SessionId, options: AcquireOptions): boolean {
    // Never mode - always use main directory
    if (this.config.isolationMode === 'never') {
      return false;
    }

    // Always mode - always isolate
    if (this.config.isolationMode === 'always') {
      return true;
    }

    // Force isolation requested
    if (options.forceIsolation) {
      return true;
    }

    // Forked session - must isolate
    if (options.parentSessionId) {
      return true;
    }

    // Another session already owns the main directory
    if (this.mainDirectoryOwner && this.mainDirectoryOwner !== (sessionId as string)) {
      return true;
    }

    // First session - no isolation needed
    return false;
  }

  // ===========================================================================
  // Worktree Creation
  // ===========================================================================

  /**
   * Acquire the main directory (no worktree)
   */
  private async acquireMainDirectory(sessionId: SessionId): Promise<WorkingDirectory> {
    const branch = await this.getCurrentBranch(this.repoRoot!);
    const commit = await this.getCurrentCommit(this.repoRoot!);

    const info: WorkingDirectoryInfo = {
      path: this.repoRoot!,
      branch,
      isolated: false,
      sessionId,
      baseCommit: commit,
    };

    const workingDir = createWorkingDirectory(info);
    this.activeSessions.set(sessionId as string, {
      sessionId,
      workingDirectory: workingDir,
      acquiredAt: new Date(),
    });
    this.mainDirectoryOwner = sessionId as string;

    // Emit acquired event
    await this.emitAcquiredEvent(sessionId, {
      path: this.repoRoot!,
      branch,
      baseCommit: commit,
      isolated: false,
    });

    logger.info('Main directory acquired', {
      sessionId,
      path: this.repoRoot,
      branch,
    });

    return workingDir;
  }

  /**
   * Acquire an isolated worktree
   */
  private async acquireIsolatedWorktree(
    sessionId: SessionId,
    options: AcquireOptions
  ): Promise<WorkingDirectory> {
    // Determine base directory for worktrees
    const worktreeBase = this.config.worktreeBaseDir || path.join(this.repoRoot!, '.worktrees');
    await fs.mkdir(worktreeBase, { recursive: true });

    // Determine branch name
    const branchName = options.branchName || `${this.config.branchPrefix}${sessionId}`;
    const worktreePath = path.join(worktreeBase, sessionId as string);

    // Determine base commit
    let baseCommit: string;
    let forkedFrom: { sessionId: SessionId; commit: string } | undefined;

    if (options.parentCommit) {
      // Fork from specific commit
      baseCommit = options.parentCommit;
      if (options.parentSessionId) {
        forkedFrom = {
          sessionId: options.parentSessionId,
          commit: options.parentCommit,
        };
      }
    } else if (options.parentSessionId) {
      // Fork from parent's current state
      const parentSession = this.activeSessions.get(options.parentSessionId as string);
      if (parentSession) {
        baseCommit = await parentSession.workingDirectory.getCurrentCommit();
        forkedFrom = {
          sessionId: options.parentSessionId,
          commit: baseCommit,
        };
      } else {
        // Parent not active, use current HEAD
        baseCommit = await this.getCurrentCommit(this.repoRoot!);
      }
    } else {
      // Branch from current HEAD
      baseCommit = await this.getCurrentCommit(this.repoRoot!);
    }

    // Check if worktree already exists
    try {
      await fs.access(worktreePath);
      // Already exists - reuse it
      logger.info('Reusing existing worktree', { sessionId, path: worktreePath });
    } catch {
      // Create new worktree
      await this.createWorktree(worktreePath, branchName, baseCommit);
    }

    const info: WorkingDirectoryInfo = {
      path: worktreePath,
      branch: branchName,
      isolated: true,
      sessionId,
      baseCommit,
    };

    const workingDir = createWorkingDirectory(info);
    this.activeSessions.set(sessionId as string, {
      sessionId,
      workingDirectory: workingDir,
      acquiredAt: new Date(),
    });

    // Emit acquired event
    await this.emitAcquiredEvent(sessionId, {
      path: worktreePath,
      branch: branchName,
      baseCommit,
      isolated: true,
      forkedFrom,
    });

    logger.info('Isolated worktree acquired', {
      sessionId,
      path: worktreePath,
      branch: branchName,
      forkedFrom: forkedFrom?.sessionId,
    });

    return workingDir;
  }

  /**
   * Acquire a non-git directory (fallback)
   */
  private async acquireNonGitDirectory(
    sessionId: SessionId,
    workingDir: string
  ): Promise<WorkingDirectory> {
    const info: WorkingDirectoryInfo = {
      path: workingDir,
      branch: 'none',
      isolated: false,
      sessionId,
      baseCommit: 'none',
    };

    const wd = createWorkingDirectory(info);
    this.activeSessions.set(sessionId as string, {
      sessionId,
      workingDirectory: wd,
      acquiredAt: new Date(),
    });

    return wd;
  }

  /**
   * Create a git worktree
   */
  private async createWorktree(
    worktreePath: string,
    branchName: string,
    baseCommit: string
  ): Promise<void> {
    // Check if branch exists
    const branchCheck = await execGit(
      ['rev-parse', '--verify', branchName],
      this.repoRoot!
    );

    if (branchCheck.exitCode !== 0) {
      // Create branch from base commit
      await execGit(
        ['branch', branchName, baseCommit],
        this.repoRoot!
      );
    }

    // Create worktree
    const result = await execGit(
      ['worktree', 'add', worktreePath, branchName],
      this.repoRoot!
    );

    if (result.exitCode !== 0) {
      throw new Error(`Failed to create worktree: ${result.stderr}`);
    }

    logger.info('Worktree created', { path: worktreePath, branch: branchName });
  }

  /**
   * Remove a worktree
   */
  private async removeWorktree(worktreePath: string): Promise<void> {
    // Check if directory exists before trying git operations
    const dirExists = await pathExists(worktreePath);

    if (!dirExists) {
      // Directory already gone - just prune stale worktree references
      logger.debug('Worktree directory already deleted, pruning references', {
        path: worktreePath,
      });
      try {
        await execGit(['worktree', 'prune'], this.repoRoot!);
      } catch {
        // Ignore prune errors
      }
      return;
    }

    const result = await execGit(
      ['worktree', 'remove', worktreePath, '--force'],
      this.repoRoot!
    );

    if (result.exitCode !== 0) {
      logger.warn('Failed to remove worktree via git', {
        path: worktreePath,
        error: result.stderr,
      });

      // Try to remove directory directly
      try {
        await fs.rm(worktreePath, { recursive: true, force: true });
        // Prune worktree references
        await execGit(['worktree', 'prune'], this.repoRoot!);
      } catch (error) {
        logger.error('Failed to remove worktree directory', {
          path: worktreePath,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  // ===========================================================================
  // Merge Operations
  // ===========================================================================

  /**
   * Merge a session's branch into a target branch
   */
  async mergeSession(
    sessionId: SessionId,
    targetBranch: string,
    strategy: 'merge' | 'rebase' | 'squash' = 'merge'
  ): Promise<{ success: boolean; mergeCommit?: string; conflicts?: string[] }> {
    const session = this.activeSessions.get(sessionId as string);
    if (!session || !session.workingDirectory.isolated) {
      return { success: false, conflicts: ['Session not found or not isolated'] };
    }

    const workingDir = session.workingDirectory;

    try {
      // Ensure everything is committed
      if (await workingDir.hasUncommittedChanges()) {
        await workingDir.commit(`Pre-merge commit for ${sessionId}`, { addAll: true });
      }

      // Check for conflicts
      const checkResult = await execGit(
        ['merge', '--no-commit', '--no-ff', workingDir.branch],
        this.repoRoot!
      );

      if (checkResult.exitCode !== 0) {
        // Abort the merge attempt
        await execGit(['merge', '--abort'], this.repoRoot!);
        return {
          success: false,
          conflicts: [checkResult.stderr],
        };
      }

      // Abort the test merge
      await execGit(['merge', '--abort'], this.repoRoot!);

      // Perform actual merge
      let mergeCommit: string;
      if (strategy === 'squash') {
        await execGit(
          ['checkout', targetBranch],
          this.repoRoot!
        );
        await execGit(
          ['merge', '--squash', workingDir.branch],
          this.repoRoot!
        );
        const commitResult = await execGit(
          ['commit', '-m', `Squash merge session ${sessionId}`],
          this.repoRoot!
        );
        if (commitResult.exitCode !== 0) {
          throw new Error(commitResult.stderr);
        }
        const hashResult = await execGit(['rev-parse', 'HEAD'], this.repoRoot!);
        mergeCommit = hashResult.stdout;
      } else {
        await execGit(
          ['checkout', targetBranch],
          this.repoRoot!
        );
        const mergeResult = await execGit(
          ['merge', '--no-ff', '-m', `Merge session ${sessionId}`, workingDir.branch],
          this.repoRoot!
        );
        if (mergeResult.exitCode !== 0) {
          throw new Error(mergeResult.stderr);
        }
        const hashResult = await execGit(['rev-parse', 'HEAD'], this.repoRoot!);
        mergeCommit = hashResult.stdout;
      }

      // Emit merge event
      await this.emitMergedEvent(sessionId, {
        sourceBranch: workingDir.branch,
        targetBranch,
        mergeCommit,
        strategy,
      });

      logger.info('Session merged', {
        sessionId,
        targetBranch,
        mergeCommit,
        strategy,
      });

      return { success: true, mergeCommit };
    } catch (error) {
      logger.error('Merge failed', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
      return {
        success: false,
        conflicts: [error instanceof Error ? error.message : String(error)],
      };
    }
  }

  // ===========================================================================
  // Event Emission
  // ===========================================================================

  private async emitAcquiredEvent(
    sessionId: SessionId,
    payload: WorktreeAcquiredEvent['payload']
  ): Promise<void> {
    try {
      await this.eventStore.append({
        sessionId,
        type: 'worktree.acquired',
        payload: payload as unknown as Record<string, unknown>,
      });
    } catch (error) {
      logger.warn('Failed to emit worktree.acquired event', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async emitReleasedEvent(
    sessionId: SessionId,
    payload: WorktreeReleasedEvent['payload']
  ): Promise<void> {
    try {
      await this.eventStore.append({
        sessionId,
        type: 'worktree.released',
        payload: payload as unknown as Record<string, unknown>,
      });
    } catch (error) {
      logger.warn('Failed to emit worktree.released event', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async emitCommitEvent(
    sessionId: SessionId,
    payload: WorktreeCommitEvent['payload']
  ): Promise<void> {
    try {
      await this.eventStore.append({
        sessionId,
        type: 'worktree.commit',
        payload: payload as unknown as Record<string, unknown>,
      });
    } catch (error) {
      logger.warn('Failed to emit worktree.commit event', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async emitMergedEvent(
    sessionId: SessionId,
    payload: WorktreeMergedEvent['payload']
  ): Promise<void> {
    try {
      await this.eventStore.append({
        sessionId,
        type: 'worktree.merged',
        payload: payload as unknown as Record<string, unknown>,
      });
    } catch (error) {
      logger.warn('Failed to emit worktree.merged event', {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  // ===========================================================================
  // Recovery
  // ===========================================================================

  /**
   * Recover orphaned worktrees from crashed sessions
   */
  async recoverOrphanedWorktrees(): Promise<void> {
    if (!this.repoRoot) {
      return;
    }

    const worktreeBase = this.config.worktreeBaseDir || path.join(this.repoRoot, '.worktrees');

    // Check if worktree base directory exists
    if (!await pathExists(worktreeBase)) {
      return;
    }

    try {
      const entries = await fs.readdir(worktreeBase, { withFileTypes: true });

      for (const entry of entries) {
        if (!entry.isDirectory()) continue;

        const sessionId = entry.name;
        const worktreePath = path.join(worktreeBase, sessionId);

        // Check if session is active
        if (this.activeSessions.has(sessionId)) {
          continue;
        }

        // Verify directory still exists (might have been deleted externally)
        if (!await pathExists(worktreePath)) {
          logger.debug('Orphaned worktree directory no longer exists', { sessionId, path: worktreePath });
          continue;
        }

        logger.info('Found orphaned worktree', { sessionId, path: worktreePath });

        try {
          // Check for uncommitted changes
          const statusResult = await execGit(['status', '--porcelain'], worktreePath);
          if (statusResult.stdout) {
            // Has uncommitted changes - commit them
            await execGit(['add', '-A'], worktreePath);
            await execGit(
              ['commit', '-m', `[RECOVERED] Session ${sessionId}`],
              worktreePath
            );
            logger.info('Committed orphaned changes', { sessionId });
          }

          // Optionally clean up
          if (this.config.deleteWorktreeOnRelease) {
            await this.removeWorktree(worktreePath);
            logger.info('Removed orphaned worktree', { sessionId });
          }
        } catch (error) {
          // Log but continue processing other worktrees
          logger.warn('Failed to recover orphaned worktree', {
            sessionId,
            path: worktreePath,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }

      // Prune any stale worktree references
      try {
        await execGit(['worktree', 'prune'], this.repoRoot);
      } catch {
        // Ignore prune errors
      }
    } catch (error) {
      logger.warn('Failed to scan for orphaned worktrees', {
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * List all worktrees (including orphaned ones)
   */
  async listWorktrees(): Promise<Array<{ path: string; branch: string; sessionId?: string }>> {
    if (!this.repoRoot) {
      return [];
    }

    const result = await execGit(['worktree', 'list', '--porcelain'], this.repoRoot);
    if (result.exitCode !== 0) {
      return [];
    }

    const worktrees: Array<{ path: string; branch: string; sessionId?: string }> = [];
    const blocks = result.stdout.split('\n\n');

    for (const block of blocks) {
      const lines = block.split('\n');
      const worktreePath = lines.find(l => l.startsWith('worktree '))?.slice(9);
      const branch = lines.find(l => l.startsWith('branch '))?.slice(7);

      if (worktreePath && branch) {
        const sessionId = branch.startsWith(`refs/heads/${this.config.branchPrefix}`)
          ? branch.replace(`refs/heads/${this.config.branchPrefix}`, '')
          : undefined;

        worktrees.push({
          path: worktreePath,
          branch: branch.replace('refs/heads/', ''),
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
 * Create a WorktreeCoordinator instance
 */
export function createWorktreeCoordinator(
  eventStore: EventStore,
  config?: WorktreeCoordinatorConfig
): WorktreeCoordinator {
  return new WorktreeCoordinator(eventStore, config);
}
