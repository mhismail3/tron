/**
 * @fileoverview Worktree Operation Helpers
 *
 * Provides helper functions for building worktree information from
 * WorkingDirectory abstractions. These are pure functions that don't
 * depend on orchestrator state.
 */
// Direct import to avoid circular dependencies through index.js
import type { WorkingDirectory } from '../session/working-directory.js';
import type { WorktreeInfo } from './types.js';

/**
 * Build WorktreeInfo from a WorkingDirectory (synchronous, basic info only)
 */
export function buildWorktreeInfo(workingDir: WorkingDirectory): WorktreeInfo {
  return {
    isolated: workingDir.isolated,
    branch: workingDir.branch,
    baseCommit: workingDir.baseCommit,
    path: workingDir.path,
  };
}

/**
 * Build WorktreeInfo with additional status information (async)
 * Includes hasUncommittedChanges and commitCount.
 */
export async function buildWorktreeInfoWithStatus(workingDir: WorkingDirectory): Promise<WorktreeInfo> {
  const info = buildWorktreeInfo(workingDir);

  try {
    info.hasUncommittedChanges = await workingDir.hasUncommittedChanges();
    const commits = await workingDir.getCommitsSinceBase();
    info.commitCount = commits.length;
  } catch {
    // Ignore errors getting status - return basic info
  }

  return info;
}

/**
 * Commit result from a worktree commit operation
 */
export interface CommitWorktreeResult {
  success: boolean;
  commitHash?: string;
  filesChanged?: string[];
  error?: string;
}

/**
 * Commit changes in a working directory
 */
export async function commitWorkingDirectory(
  workingDir: WorkingDirectory,
  message: string
): Promise<CommitWorktreeResult> {
  try {
    const result = await workingDir.commit(message, { addAll: true });
    if (!result) {
      return { success: true, filesChanged: [] }; // Nothing to commit
    }

    return {
      success: true,
      commitHash: result.hash,
      filesChanged: result.filesChanged,
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
