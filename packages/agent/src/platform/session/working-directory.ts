/**
 * @fileoverview Working Directory Abstraction
 *
 * Provides a unified interface for sessions to interact with their
 * working directory, whether it's the main repository or an isolated worktree.
 *
 * Key features:
 * - Abstracts away worktree vs main directory differences
 * - Tracks file modifications for event logging
 * - Provides git operations (commit, diff, status)
 */

import * as path from 'path';
import { createLogger } from '@infrastructure/logging/index.js';
import { createGitExecutor } from './worktree/git-executor.js';
import type { SessionId } from '@infrastructure/events/types.js';

const logger = createLogger('working-directory');

// Shared git executor instance for all working directories
const gitExecutor = createGitExecutor();

// =============================================================================
// Types
// =============================================================================

export interface WorkingDirectoryInfo {
  /** Filesystem path to working directory */
  path: string;
  /** Git branch name */
  branch: string;
  /** Whether this is an isolated worktree */
  isolated: boolean;
  /** Session that owns this directory */
  sessionId: SessionId;
  /** Base commit when acquired */
  baseCommit: string;
}

export interface FileModification {
  path: string;
  operation: 'create' | 'modify' | 'delete';
  timestamp: string;
}

export interface GitStatus {
  /** Number of files changed */
  filesChanged: number;
  /** Number of insertions */
  insertions: number;
  /** Number of deletions */
  deletions: number;
  /** List of modified files */
  modifiedFiles: string[];
  /** Whether there are uncommitted changes */
  isDirty: boolean;
  /** Current branch */
  branch: string;
  /** Current commit hash */
  commit: string;
}

export interface CommitResult {
  /** Commit hash */
  hash: string;
  /** Files included in commit */
  filesChanged: string[];
  /** Number of insertions */
  insertions: number;
  /** Number of deletions */
  deletions: number;
}

// =============================================================================
// WorkingDirectory Class
// =============================================================================

/**
 * Represents a session's working directory.
 *
 * This abstraction hides whether the session is using the main directory
 * or an isolated worktree. All git operations go through this class.
 */
export class WorkingDirectory {
  private modifications: FileModification[] = [];

  constructor(private readonly info: WorkingDirectoryInfo) {}

  // ===========================================================================
  // Properties
  // ===========================================================================

  /** Filesystem path */
  get path(): string {
    return this.info.path;
  }

  /** Git branch name */
  get branch(): string {
    return this.info.branch;
  }

  /** Whether this is an isolated worktree */
  get isolated(): boolean {
    return this.info.isolated;
  }

  /** Session ID that owns this directory */
  get sessionId(): SessionId {
    return this.info.sessionId;
  }

  /** Base commit when acquired */
  get baseCommit(): string {
    return this.info.baseCommit;
  }

  /** Get full info */
  getInfo(): WorkingDirectoryInfo {
    return { ...this.info };
  }

  // ===========================================================================
  // File Modification Tracking
  // ===========================================================================

  /**
   * Record a file modification for later event logging
   */
  recordModification(filePath: string, operation: 'create' | 'modify' | 'delete'): void {
    // Normalize path relative to working directory
    const relativePath = path.isAbsolute(filePath)
      ? path.relative(this.info.path, filePath)
      : filePath;

    this.modifications.push({
      path: relativePath,
      operation,
      timestamp: new Date().toISOString(),
    });

    logger.debug('File modification recorded', {
      sessionId: this.info.sessionId,
      path: relativePath,
      operation,
    });
  }

  /**
   * Get all recorded modifications
   */
  getModifications(): FileModification[] {
    return [...this.modifications];
  }

  /**
   * Clear recorded modifications (after committing)
   */
  clearModifications(): void {
    this.modifications = [];
  }

  // ===========================================================================
  // Git Operations
  // ===========================================================================

  /**
   * Get current git status
   */
  async getStatus(): Promise<GitStatus> {
    // Get current branch
    const branchResult = await gitExecutor.execGit(
      ['rev-parse', '--abbrev-ref', 'HEAD'],
      this.info.path
    );
    const branch = branchResult.stdout || this.info.branch;

    // Get current commit
    const commitResult = await gitExecutor.execGit(
      ['rev-parse', 'HEAD'],
      this.info.path
    );
    const commit = commitResult.stdout;

    // Get status
    const statusResult = await gitExecutor.execGit(
      ['status', '--porcelain'],
      this.info.path
    );
    const modifiedFiles = statusResult.stdout
      .split('\n')
      .filter(line => line.trim())
      .map(line => line.slice(3));

    // Get diff stats
    const diffResult = await gitExecutor.execGit(
      ['diff', '--stat', '--stat-count=100'],
      this.info.path
    );

    let insertions = 0;
    let deletions = 0;
    const statMatch = diffResult.stdout.match(/(\d+) insertions?.*?(\d+) deletions?/);
    if (statMatch) {
      insertions = parseInt(statMatch[1] || '0', 10);
      deletions = parseInt(statMatch[2] || '0', 10);
    }

    return {
      filesChanged: modifiedFiles.length,
      insertions,
      deletions,
      modifiedFiles,
      isDirty: modifiedFiles.length > 0,
      branch,
      commit,
    };
  }

  /**
   * Get diff from base commit or specified commit
   */
  async getDiff(base?: string): Promise<string> {
    const baseRef = base || this.info.baseCommit;
    const result = await gitExecutor.execGit(
      ['diff', baseRef, 'HEAD'],
      this.info.path
    );
    return result.stdout;
  }

  /**
   * Get diff of uncommitted changes
   */
  async getUncommittedDiff(): Promise<string> {
    // Get both staged and unstaged changes
    const stagedResult = await gitExecutor.execGit(['diff', '--cached'], this.info.path);
    const unstagedResult = await gitExecutor.execGit(['diff'], this.info.path);
    return stagedResult.stdout + '\n' + unstagedResult.stdout;
  }

  /**
   * Stage all changes
   */
  async stageAll(): Promise<void> {
    await gitExecutor.execGit(['add', '-A'], this.info.path);
  }

  /**
   * Commit staged changes
   */
  async commit(message: string, options?: { addAll?: boolean }): Promise<CommitResult | null> {
    if (options?.addAll) {
      await this.stageAll();
    }

    // Check if there's anything to commit
    const status = await this.getStatus();
    if (!status.isDirty) {
      logger.debug('Nothing to commit', { sessionId: this.info.sessionId });
      return null;
    }

    // Get list of files before commit
    const filesResult = await gitExecutor.execGit(['diff', '--cached', '--name-only'], this.info.path);
    const filesChanged = filesResult.stdout.split('\n').filter(f => f.trim());

    // Commit
    const result = await gitExecutor.execGit(
      ['commit', '-m', message],
      this.info.path
    );

    if (result.exitCode !== 0 && !result.stderr.includes('nothing to commit')) {
      throw new Error(`Commit failed: ${result.stderr}`);
    }

    // Get commit hash
    const hashResult = await gitExecutor.execGit(['rev-parse', 'HEAD'], this.info.path);
    const hash = hashResult.stdout;

    // Get stats
    const statsResult = await gitExecutor.execGit(
      ['diff', '--stat', 'HEAD~1..HEAD'],
      this.info.path
    );

    let insertions = 0;
    let deletions = 0;
    const statMatch = statsResult.stdout.match(/(\d+) insertions?.*?(\d+) deletions?/);
    if (statMatch) {
      insertions = parseInt(statMatch[1] || '0', 10);
      deletions = parseInt(statMatch[2] || '0', 10);
    }

    logger.info('Changes committed', {
      sessionId: this.info.sessionId,
      hash,
      filesChanged: filesChanged.length,
    });

    // Clear tracked modifications since they're now committed
    this.clearModifications();

    return {
      hash,
      filesChanged,
      insertions,
      deletions,
    };
  }

  /**
   * Get the current HEAD commit
   */
  async getCurrentCommit(): Promise<string> {
    const result = await gitExecutor.execGit(['rev-parse', 'HEAD'], this.info.path);
    return result.stdout;
  }

  /**
   * Check if there are uncommitted changes
   */
  async hasUncommittedChanges(): Promise<boolean> {
    const status = await this.getStatus();
    return status.isDirty;
  }

  /**
   * Get commits since base
   */
  async getCommitsSinceBase(): Promise<Array<{ hash: string; message: string; timestamp: string }>> {
    const result = await gitExecutor.execGit(
      ['log', `${this.info.baseCommit}..HEAD`, '--pretty=format:%H|%s|%aI'],
      this.info.path
    );

    if (!result.stdout) {
      return [];
    }

    return result.stdout.split('\n').filter(line => line.trim()).map(line => {
      const parts = line.split('|');
      return {
        hash: parts[0] || '',
        message: parts[1] || '',
        timestamp: parts[2] || ''
      };
    });
  }

  /**
   * Resolve a relative path to absolute
   */
  resolve(...segments: string[]): string {
    return path.join(this.info.path, ...segments);
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a WorkingDirectory instance
 */
export function createWorkingDirectory(info: WorkingDirectoryInfo): WorkingDirectory {
  return new WorkingDirectory(info);
}
