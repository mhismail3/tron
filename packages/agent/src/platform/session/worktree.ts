/**
 * @fileoverview Git Worktree Integration
 *
 * Provides automatic git worktree management for isolated session work.
 * Each session can optionally work in its own worktree to avoid conflicts.
 *
 * @example
 * ```typescript
 * const worktreeManager = new WorktreeManager({
 *   baseDir: '/home/user/project-worktrees',
 *   branchPrefix: 'session/',
 * });
 *
 * const worktree = await worktreeManager.createForSession('session-123', '/home/user/project');
 * // Work in worktree.path
 * await worktreeManager.cleanup('session-123');
 * ```
 */
import { spawn, execSync } from 'child_process';
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';

const logger = createLogger('worktree');

// =============================================================================
// Types
// =============================================================================

export interface WorktreeManagerConfig {
  /** Base directory for worktrees (default: .worktrees in repo root) */
  baseDir?: string;
  /** Prefix for branch names (default: 'session/') */
  branchPrefix?: string;
  /** Whether to auto-commit changes before cleanup */
  autoCommitOnCleanup?: boolean;
  /** Whether to delete branch after cleanup */
  deleteBranchOnCleanup?: boolean;
}

export interface Worktree {
  /** Session ID this worktree belongs to */
  sessionId: string;
  /** Absolute path to worktree */
  path: string;
  /** Branch name */
  branch: string;
  /** HEAD commit when created */
  baseCommit: string;
  /** Whether this worktree is currently active */
  isActive: boolean;
  /** Creation timestamp */
  createdAt: string;
  /** Last activity timestamp */
  lastActivityAt: string;
}

export interface WorktreeStatus {
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
}

// =============================================================================
// Git Command Helpers
// =============================================================================

async function execGit(
  args: string[],
  options: { cwd: string; timeout?: number }
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return new Promise((resolve, reject) => {
    const timeout = options.timeout ?? 30000;
    const proc = spawn('git', args, {
      cwd: options.cwd,
      timeout,
    });

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

function execGitSync(args: string[], cwd: string): string {
  try {
    return execSync(`git ${args.join(' ')}`, { cwd, encoding: 'utf-8' }).trim();
  } catch {
    return '';
  }
}

// =============================================================================
// Worktree Manager Implementation
// =============================================================================

export class WorktreeManager {
  private config: Required<WorktreeManagerConfig>;
  private worktrees: Map<string, Worktree> = new Map();

  constructor(config: WorktreeManagerConfig = {}) {
    this.config = {
      baseDir: '',
      branchPrefix: 'session/',
      autoCommitOnCleanup: true,
      deleteBranchOnCleanup: false,
      ...config,
    };
  }

  /**
   * Check if a directory is a git repository
   */
  async isGitRepo(dir: string): Promise<boolean> {
    try {
      const result = await execGit(['rev-parse', '--git-dir'], { cwd: dir });
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }

  /**
   * Get the root directory of a git repository
   */
  async getRepoRoot(dir: string): Promise<string | null> {
    try {
      const result = await execGit(['rev-parse', '--show-toplevel'], { cwd: dir });
      return result.exitCode === 0 ? result.stdout : null;
    } catch {
      return null;
    }
  }

  /**
   * Create a worktree for a session
   */
  async createForSession(
    sessionId: string,
    repoPath: string,
    options?: { baseBranch?: string }
  ): Promise<Worktree> {
    const repoRoot = await this.getRepoRoot(repoPath);
    if (!repoRoot) {
      throw new Error(`Not a git repository: ${repoPath}`);
    }

    // Determine base directory
    const baseDir = this.config.baseDir || path.join(repoRoot, '.worktrees');
    await fs.mkdir(baseDir, { recursive: true });

    // Generate branch and worktree path
    const branchName = `${this.config.branchPrefix}${sessionId}`;
    const worktreePath = path.join(baseDir, sessionId);

    // Get current HEAD
    const baseCommit = execGitSync(['rev-parse', 'HEAD'], repoRoot);

    // Determine base branch
    const baseBranch = options?.baseBranch || execGitSync(['symbolic-ref', '--short', 'HEAD'], repoRoot) || 'main';

    // Check if worktree already exists
    const existingWorktree = this.worktrees.get(sessionId);
    if (existingWorktree) {
      logger.info('Returning existing worktree', { sessionId, path: existingWorktree.path });
      return existingWorktree;
    }

    // Check if path already exists
    try {
      await fs.access(worktreePath);
      // Path exists, try to use it
      const worktree: Worktree = {
        sessionId,
        path: worktreePath,
        branch: branchName,
        baseCommit,
        isActive: true,
        createdAt: new Date().toISOString(),
        lastActivityAt: new Date().toISOString(),
      };
      this.worktrees.set(sessionId, worktree);
      return worktree;
    } catch {
      // Path doesn't exist, create new worktree
    }

    // Create new branch and worktree
    try {
      // Create branch from base
      await execGit(['branch', branchName, baseBranch], { cwd: repoRoot });

      // Create worktree
      const result = await execGit(['worktree', 'add', worktreePath, branchName], { cwd: repoRoot });

      if (result.exitCode !== 0) {
        // Branch might already exist, try without creating it
        const retryResult = await execGit(['worktree', 'add', worktreePath, branchName], { cwd: repoRoot });
        if (retryResult.exitCode !== 0) {
          throw new Error(`Failed to create worktree: ${retryResult.stderr}`);
        }
      }

      const worktree: Worktree = {
        sessionId,
        path: worktreePath,
        branch: branchName,
        baseCommit,
        isActive: true,
        createdAt: new Date().toISOString(),
        lastActivityAt: new Date().toISOString(),
      };

      this.worktrees.set(sessionId, worktree);

      logger.info('Worktree created', {
        sessionId,
        path: worktreePath,
        branch: branchName,
      });

      return worktree;
    } catch (error) {
      const structured = categorizeError(error, { sessionId, operation: 'createWorktree' });
      logger.error('Failed to create worktree', {
        sessionId,
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw error;
    }
  }

  /**
   * Get a worktree by session ID
   */
  get(sessionId: string): Worktree | undefined {
    return this.worktrees.get(sessionId);
  }

  /**
   * List all active worktrees
   */
  async list(repoPath?: string): Promise<Worktree[]> {
    if (!repoPath) {
      return Array.from(this.worktrees.values());
    }

    const repoRoot = await this.getRepoRoot(repoPath);
    if (!repoRoot) {
      return [];
    }

    const result = await execGit(['worktree', 'list', '--porcelain'], { cwd: repoRoot });
    if (result.exitCode !== 0) {
      return [];
    }

    const worktrees: Worktree[] = [];
    const blocks = result.stdout.split('\n\n');

    for (const block of blocks) {
      const lines = block.split('\n');
      const worktreePath = lines.find(l => l.startsWith('worktree '))?.slice(9);
      const branch = lines.find(l => l.startsWith('branch '))?.slice(7);

      if (worktreePath && branch?.startsWith(`refs/heads/${this.config.branchPrefix}`)) {
        const sessionId = branch.replace(`refs/heads/${this.config.branchPrefix}`, '');
        worktrees.push({
          sessionId,
          path: worktreePath,
          branch: branch.replace('refs/heads/', ''),
          baseCommit: '',
          isActive: true,
          createdAt: '',
          lastActivityAt: '',
        });
      }
    }

    return worktrees;
  }

  /**
   * Get status of a worktree
   */
  async getStatus(sessionId: string): Promise<WorktreeStatus | null> {
    const worktree = this.worktrees.get(sessionId);
    if (!worktree) {
      return null;
    }

    const result = await execGit(['status', '--porcelain'], { cwd: worktree.path });
    const diffStat = await execGit(['diff', '--stat', '--stat-count=100'], { cwd: worktree.path });

    const modifiedFiles = result.stdout
      .split('\n')
      .filter(line => line.trim())
      .map(line => line.slice(3));

    // Parse diff stat
    let insertions = 0;
    let deletions = 0;
    const statMatch = diffStat.stdout.match(/(\d+) insertions?.*?(\d+) deletions?/);
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
    };
  }

  /**
   * Commit changes in a worktree
   */
  async commit(
    sessionId: string,
    message: string,
    options?: { addAll?: boolean }
  ): Promise<string | null> {
    const worktree = this.worktrees.get(sessionId);
    if (!worktree) {
      return null;
    }

    try {
      if (options?.addAll) {
        await execGit(['add', '-A'], { cwd: worktree.path });
      }

      const result = await execGit(['commit', '-m', message], { cwd: worktree.path });

      if (result.exitCode !== 0 && !result.stderr.includes('nothing to commit')) {
        throw new Error(result.stderr);
      }

      // Get commit hash
      const hashResult = await execGit(['rev-parse', 'HEAD'], { cwd: worktree.path });
      const commitHash = hashResult.stdout;

      logger.info('Changes committed', { sessionId, commit: commitHash });
      return commitHash;
    } catch (error) {
      const structured = categorizeError(error, { sessionId, operation: 'commit' });
      logger.error('Failed to commit', {
        sessionId,
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw error;
    }
  }

  /**
   * Cleanup a worktree
   */
  async cleanup(
    sessionId: string,
    repoPath?: string
  ): Promise<boolean> {
    const worktree = this.worktrees.get(sessionId);

    const worktreePath = worktree?.path;
    const branchName = worktree?.branch || `${this.config.branchPrefix}${sessionId}`;

    if (!worktreePath && !repoPath) {
      return false;
    }

    const cwd = repoPath || (worktreePath ? path.dirname(worktreePath) : '');
    if (!cwd) {
      return false;
    }

    const repoRoot = await this.getRepoRoot(cwd);
    if (!repoRoot) {
      return false;
    }

    try {
      // Auto-commit if configured and there are changes
      if (this.config.autoCommitOnCleanup && worktreePath) {
        const status = await this.getStatus(sessionId);
        if (status?.isDirty) {
          await this.commit(sessionId, `Session ${sessionId} auto-save`, { addAll: true });
        }
      }

      // Remove worktree
      if (worktreePath) {
        await execGit(['worktree', 'remove', worktreePath, '--force'], { cwd: repoRoot });
      }

      // Delete branch if configured
      if (this.config.deleteBranchOnCleanup) {
        await execGit(['branch', '-D', branchName], { cwd: repoRoot });
      }

      this.worktrees.delete(sessionId);

      logger.info('Worktree cleaned up', { sessionId });
      return true;
    } catch (error) {
      const structured = categorizeError(error, { sessionId, operation: 'cleanupWorktree' });
      logger.error('Failed to cleanup worktree', {
        sessionId,
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
      });
      return false;
    }
  }

  /**
   * Merge a session branch back to main
   */
  async merge(
    sessionId: string,
    targetBranch: string = 'main'
  ): Promise<boolean> {
    const worktree = this.worktrees.get(sessionId);
    if (!worktree) {
      return false;
    }

    const repoRoot = await this.getRepoRoot(worktree.path);
    if (!repoRoot) {
      return false;
    }

    try {
      // Switch to target branch in main worktree
      await execGit(['checkout', targetBranch], { cwd: repoRoot });

      // Merge session branch
      const result = await execGit(['merge', worktree.branch, '--no-ff', '-m', `Merge session ${sessionId}`], { cwd: repoRoot });

      if (result.exitCode !== 0) {
        throw new Error(`Merge failed: ${result.stderr}`);
      }

      logger.info('Session merged', { sessionId, target: targetBranch });
      return true;
    } catch (error) {
      const structured = categorizeError(error, { sessionId, operation: 'mergeSession' });
      logger.error('Failed to merge session', {
        sessionId,
        code: structured.code,
        category: LogErrorCategory.SESSION_STATE,
        error: structured.message,
        retryable: structured.retryable,
      });
      return false;
    }
  }

  /**
   * Switch to a worktree
   */
  getPath(sessionId: string): string | null {
    return this.worktrees.get(sessionId)?.path || null;
  }

  /**
   * Update activity timestamp
   */
  touch(sessionId: string): void {
    const worktree = this.worktrees.get(sessionId);
    if (worktree) {
      worktree.lastActivityAt = new Date().toISOString();
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createWorktreeManager(config?: WorktreeManagerConfig): WorktreeManager {
  return new WorktreeManager(config);
}
