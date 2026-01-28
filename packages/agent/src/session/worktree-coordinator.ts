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
 *
 * Delegated to handlers:
 * - GitExecutor: Low-level git command execution
 * - WorktreeEvents: Event emission
 *
 * Available for future delegation (tested, in worktree/ folder):
 * - WorktreeLifecycle: Worktree CRUD operations
 * - MergeHandler: Merge/rebase/squash strategies
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '../logging/index.js';
import { WorkingDirectory, createWorkingDirectory } from './working-directory.js';
import type { WorkingDirectoryInfo } from './working-directory.js';
import type { EventStore } from '../events/event-store.js';
import type { SessionId } from '../events/types.js';
import {
  GitExecutor,
  createGitExecutor,
  WorktreeEvents,
  createWorktreeEvents,
  IsolationPolicy,
  createIsolationPolicy,
  WorktreeLifecycle,
  createWorktreeLifecycle,
  WorktreeRecovery,
  createWorktreeRecovery,
} from './worktree/index.js';

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

  // Handlers for delegated operations
  private gitExecutor: GitExecutor;
  private worktreeEvents: WorktreeEvents;
  private isolationPolicy: IsolationPolicy | null = null;
  private worktreeLifecycle: WorktreeLifecycle | null = null;
  private worktreeRecovery: WorktreeRecovery | null = null;

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

    // Initialize handlers that don't need repo root
    this.gitExecutor = createGitExecutor();
    this.worktreeEvents = createWorktreeEvents({
      eventStore: {
        append: async (sessionId, type, payload) => {
          await this.eventStore.append({
            sessionId,
            type: type as import('../events/types.js').EventType,
            payload: payload as Record<string, unknown>,
          });
          return 'event-id';
        },
      },
    });
  }

  /**
   * Initialize handlers that need repoRoot (called lazily when repoRoot is set)
   */
  private initializeHandlers(): void {
    if (!this.repoRoot) return;

    const worktreeBaseDir = this.config.worktreeBaseDir || path.join(this.repoRoot, '.worktrees');

    // IsolationPolicy
    this.isolationPolicy = createIsolationPolicy({
      isolationMode: this.config.isolationMode,
      getMainDirectoryOwner: () => this.mainDirectoryOwner,
    });

    // WorktreeLifecycle
    this.worktreeLifecycle = createWorktreeLifecycle({
      gitExecutor: this.gitExecutor,
      repoRoot: this.repoRoot,
      worktreeBaseDir,
      branchPrefix: this.config.branchPrefix,
    });

    // WorktreeRecovery
    this.worktreeRecovery = createWorktreeRecovery({
      gitExecutor: this.gitExecutor,
      repoRoot: this.repoRoot,
      worktreeBaseDir,
      isSessionActive: (sessionId: string) => this.activeSessions.has(sessionId),
      deleteOnRecovery: this.config.deleteWorktreeOnRelease,
    });
  }

  // ===========================================================================
  // Repository Detection (delegated to GitExecutor)
  // ===========================================================================

  /**
   * Check if a directory is inside a git repository
   */
  async isGitRepo(dir: string): Promise<boolean> {
    return this.gitExecutor.isGitRepo(dir);
  }

  /**
   * Get the root directory of the git repository
   */
  async getRepoRoot(dir: string): Promise<string | null> {
    return this.gitExecutor.getRepoRoot(dir);
  }

  /**
   * Get current branch name
   */
  async getCurrentBranch(dir: string): Promise<string> {
    return this.gitExecutor.getCurrentBranch(dir);
  }

  /**
   * Get current commit hash
   */
  async getCurrentCommit(dir: string): Promise<string> {
    return this.gitExecutor.getCurrentCommit(dir);
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

    // Initialize handlers that need repoRoot
    this.initializeHandlers();

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
    const dirExists = await this.gitExecutor.pathExists(workingDir.path);
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
      if (this.repoRoot && await this.gitExecutor.pathExists(this.repoRoot)) {
        try {
          await this.gitExecutor.execGit(['worktree', 'prune'], this.repoRoot);
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
      const structured = categorizeError(error, { sessionId, operation: 'release' });
      logger.error('Failed to release working directory', {
        sessionId,
        code: LogErrorCodes.SESS_INVALID,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
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
  // Isolation Decision (delegated to IsolationPolicy)
  // ===========================================================================

  /**
   * Determine if a session needs an isolated worktree
   */
  private shouldIsolate(sessionId: SessionId, options: AcquireOptions): boolean {
    // Use the IsolationPolicy if available, otherwise inline logic for non-git case
    if (this.isolationPolicy) {
      return this.isolationPolicy.shouldIsolate(sessionId, {
        forceIsolation: options.forceIsolation,
        parentSessionId: options.parentSessionId,
      });
    }

    // Fallback for when handlers aren't initialized (shouldn't happen)
    return options.forceIsolation || !!options.parentSessionId;
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
   * Create a git worktree (delegated to WorktreeLifecycle)
   */
  private async createWorktree(
    worktreePath: string,
    branchName: string,
    baseCommit: string
  ): Promise<void> {
    if (!this.worktreeLifecycle) {
      throw new Error('WorktreeLifecycle not initialized');
    }

    await this.worktreeLifecycle.createWorktree(worktreePath, branchName, baseCommit);
    logger.info('Worktree created', { path: worktreePath, branch: branchName });
  }

  /**
   * Remove a worktree (delegated to WorktreeLifecycle)
   */
  private async removeWorktree(worktreePath: string): Promise<void> {
    if (!this.worktreeLifecycle) {
      // Fallback if lifecycle not initialized
      logger.warn('WorktreeLifecycle not initialized, skipping worktree removal');
      return;
    }

    try {
      await this.worktreeLifecycle.removeWorktree(worktreePath, { force: true });
    } catch (error) {
      const structured = categorizeError(error, { path: worktreePath, operation: 'remove-worktree' });
      logger.error('Failed to remove worktree', {
        path: worktreePath,
        code: structured.code,
        category: LogErrorCategory.FILESYSTEM,
        error: structured.message,
        retryable: structured.retryable,
      });
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
      const checkResult = await this.gitExecutor.execGit(
        ['merge', '--no-commit', '--no-ff', workingDir.branch],
        this.repoRoot!
      );

      if (checkResult.exitCode !== 0) {
        // Abort the merge attempt
        await this.gitExecutor.execGit(['merge', '--abort'], this.repoRoot!);
        return {
          success: false,
          conflicts: [checkResult.stderr],
        };
      }

      // Abort the test merge
      await this.gitExecutor.execGit(['merge', '--abort'], this.repoRoot!);

      // Perform actual merge
      let mergeCommit: string;
      if (strategy === 'squash') {
        await this.gitExecutor.execGit(
          ['checkout', targetBranch],
          this.repoRoot!
        );
        await this.gitExecutor.execGit(
          ['merge', '--squash', workingDir.branch],
          this.repoRoot!
        );
        const commitResult = await this.gitExecutor.execGit(
          ['commit', '-m', `Squash merge session ${sessionId}`],
          this.repoRoot!
        );
        if (commitResult.exitCode !== 0) {
          throw new Error(commitResult.stderr);
        }
        const hashResult = await this.gitExecutor.execGit(['rev-parse', 'HEAD'], this.repoRoot!);
        mergeCommit = hashResult.stdout;
      } else {
        await this.gitExecutor.execGit(
          ['checkout', targetBranch],
          this.repoRoot!
        );
        const mergeResult = await this.gitExecutor.execGit(
          ['merge', '--no-ff', '-m', `Merge session ${sessionId}`, workingDir.branch],
          this.repoRoot!
        );
        if (mergeResult.exitCode !== 0) {
          throw new Error(mergeResult.stderr);
        }
        const hashResult = await this.gitExecutor.execGit(['rev-parse', 'HEAD'], this.repoRoot!);
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
      const structured = categorizeError(error, { sessionId, operation: 'merge', targetBranch });
      logger.error('Merge failed', {
        sessionId,
        code: LogErrorCodes.SESS_CONFLICT,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
      });
      return {
        success: false,
        conflicts: [structured.message],
      };
    }
  }

  // ===========================================================================
  // Event Emission (delegated to WorktreeEvents)
  // ===========================================================================

  private async emitAcquiredEvent(
    sessionId: SessionId,
    payload: { path: string; branch: string; baseCommit: string; isolated: boolean; forkedFrom?: { sessionId: SessionId; commit: string } }
  ): Promise<void> {
    try {
      await this.worktreeEvents.emitAcquired(sessionId, payload);
    } catch (error) {
      const structured = categorizeError(error, { sessionId, event: 'worktree.acquired' });
      logger.warn('Failed to emit worktree.acquired event', {
        sessionId,
        code: LogErrorCodes.EVNT_PERSIST,
        category: LogErrorCategory.EVENT_PERSIST,
        error: structured.message,
      });
    }
  }

  private async emitReleasedEvent(
    sessionId: SessionId,
    payload: { finalCommit?: string; deleted?: boolean; branchPreserved?: boolean }
  ): Promise<void> {
    try {
      const session = this.activeSessions.get(sessionId as string);
      const path = session?.workingDirectory?.path ?? '';
      const branch = session?.workingDirectory?.branch ?? '';
      await this.worktreeEvents.emitReleased(sessionId, {
        path,
        branch,
        finalCommit: payload.finalCommit,
        branchDeleted: !payload.branchPreserved,
        worktreeDeleted: payload.deleted,
      });
    } catch (error) {
      const structured = categorizeError(error, { sessionId, event: 'worktree.released' });
      logger.warn('Failed to emit worktree.released event', {
        sessionId,
        code: LogErrorCodes.EVNT_PERSIST,
        category: LogErrorCategory.EVENT_PERSIST,
        error: structured.message,
      });
    }
  }

  private async emitCommitEvent(
    sessionId: SessionId,
    payload: { commitHash: string; message: string; filesChanged?: string[]; insertions?: number; deletions?: number }
  ): Promise<void> {
    try {
      await this.worktreeEvents.emitCommit(sessionId, {
        hash: payload.commitHash,
        message: payload.message,
        filesChanged: payload.filesChanged,
        insertions: payload.insertions,
        deletions: payload.deletions,
      });
    } catch (error) {
      const structured = categorizeError(error, { sessionId, event: 'worktree.commit' });
      logger.warn('Failed to emit worktree.commit event', {
        sessionId,
        code: LogErrorCodes.EVNT_PERSIST,
        category: LogErrorCategory.EVENT_PERSIST,
        error: structured.message,
      });
    }
  }

  private async emitMergedEvent(
    sessionId: SessionId,
    payload: { sourceBranch: string; targetBranch: string; mergeCommit?: string; strategy: 'merge' | 'rebase' | 'squash' }
  ): Promise<void> {
    try {
      await this.worktreeEvents.emitMerged(sessionId, {
        success: !!payload.mergeCommit,
        strategy: payload.strategy,
        targetBranch: payload.targetBranch,
        sourceBranch: payload.sourceBranch,
        commitHash: payload.mergeCommit,
      });
    } catch (error) {
      const structured = categorizeError(error, { sessionId, event: 'worktree.merged' });
      logger.warn('Failed to emit worktree.merged event', {
        sessionId,
        code: LogErrorCodes.EVNT_PERSIST,
        category: LogErrorCategory.EVENT_PERSIST,
        error: structured.message,
      });
    }
  }

  // ===========================================================================
  // Recovery (delegated to WorktreeRecovery)
  // ===========================================================================

  /**
   * Recover orphaned worktrees from crashed sessions
   */
  async recoverOrphanedWorktrees(): Promise<void> {
    if (!this.worktreeRecovery) {
      // Initialize handlers if we have repoRoot but handlers aren't set up yet
      if (this.repoRoot) {
        this.initializeHandlers();
      }
      if (!this.worktreeRecovery) {
        return;
      }
    }

    const results = await this.worktreeRecovery.recoverOrphaned();

    // Log summary
    const recovered = results.filter(r => r.committed);
    const deleted = results.filter(r => r.deleted);
    if (recovered.length > 0 || deleted.length > 0) {
      logger.info('Orphaned worktree recovery complete', {
        recoveredCount: recovered.length,
        deletedCount: deleted.length,
      });
    }
  }

  /**
   * List all worktrees (including orphaned ones)
   * Delegated to WorktreeLifecycle
   */
  async listWorktrees(): Promise<Array<{ path: string; branch: string; sessionId?: string }>> {
    if (!this.worktreeLifecycle) {
      return [];
    }

    const worktrees = await this.worktreeLifecycle.listWorktrees();
    return worktrees.map(wt => ({
      path: wt.path,
      branch: wt.branch,
      sessionId: wt.sessionId,
    }));
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
