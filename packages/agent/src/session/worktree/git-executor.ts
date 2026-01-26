/**
 * @fileoverview Git Executor
 *
 * Low-level git command execution and repository operations.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import { spawn } from 'child_process';
import * as fs from 'fs/promises';
import type { GitExecResult, GitExecOptions } from './types.js';

// =============================================================================
// GitExecutor
// =============================================================================

/**
 * Executes git commands and provides repository utilities.
 */
export class GitExecutor {
  constructor(private defaultTimeout: number = 30000) {}

  /**
   * Execute a git command.
   */
  async execGit(
    args: string[],
    cwd: string,
    options?: GitExecOptions
  ): Promise<GitExecResult> {
    return new Promise((resolve, reject) => {
      const timeout = options?.timeout ?? this.defaultTimeout;
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

  /**
   * Check if a path exists on the filesystem.
   */
  async pathExists(path: string): Promise<boolean> {
    try {
      await fs.access(path);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Check if a directory is inside a git repository.
   */
  async isGitRepo(dir: string): Promise<boolean> {
    try {
      const result = await this.execGit(['rev-parse', '--is-inside-work-tree'], dir);
      return result.exitCode === 0 && result.stdout === 'true';
    } catch {
      return false;
    }
  }

  /**
   * Get the root directory of the git repository.
   */
  async getRepoRoot(dir: string): Promise<string | null> {
    try {
      const result = await this.execGit(['rev-parse', '--show-toplevel'], dir);
      if (result.exitCode === 0 && result.stdout) {
        return result.stdout;
      }
      return null;
    } catch {
      return null;
    }
  }

  /**
   * Get current branch name.
   * Returns 'HEAD' if in detached HEAD state.
   */
  async getCurrentBranch(dir: string): Promise<string> {
    const result = await this.execGit(['rev-parse', '--abbrev-ref', 'HEAD'], dir);
    return result.stdout || 'HEAD';
  }

  /**
   * Get current commit hash.
   */
  async getCurrentCommit(dir: string): Promise<string> {
    const result = await this.execGit(['rev-parse', 'HEAD'], dir);
    return result.stdout;
  }

  /**
   * Check if a branch exists.
   */
  async branchExists(dir: string, branch: string): Promise<boolean> {
    const result = await this.execGit(['rev-parse', '--verify', `refs/heads/${branch}`], dir);
    return result.exitCode === 0;
  }

  /**
   * Check if there are uncommitted changes (staged, unstaged, or untracked).
   */
  async hasUncommittedChanges(dir: string): Promise<boolean> {
    // Check for staged or unstaged changes
    const statusResult = await this.execGit(['status', '--porcelain'], dir);
    return statusResult.stdout.length > 0;
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a GitExecutor instance.
 */
export function createGitExecutor(defaultTimeout?: number): GitExecutor {
  return new GitExecutor(defaultTimeout);
}
