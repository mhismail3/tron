/**
 * @fileoverview Git RPC Types
 *
 * Types for git operations methods.
 */

// =============================================================================
// Git Methods
// =============================================================================

/** Clone a Git repository */
export interface GitCloneParams {
  /** GitHub repository URL */
  url: string;
  /** Absolute destination path for the cloned repository */
  targetPath: string;
}

export interface GitCloneResult {
  /** Whether the clone was successful */
  success: boolean;
  /** Final cloned path (absolute) */
  path: string;
  /** Extracted repository name */
  repoName: string;
  /** Error message if clone failed */
  error?: string;
}
