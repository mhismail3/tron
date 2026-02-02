/**
 * @fileoverview Git RPC Handlers
 *
 * Handlers for git.* RPC methods:
 * - git.clone: Clone a Git repository to a target path
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import * as path from 'path';
import * as fs from 'fs/promises';
import { spawn } from 'child_process';
import type { GitCloneParams, GitCloneResult } from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode, InvalidParamsError } from './base.js';

// =============================================================================
// Constants
// =============================================================================

/** Clone timeout: 5 minutes for large repos */
const CLONE_TIMEOUT_MS = 5 * 60 * 1000;

/** Valid GitHub URL pattern */
const GITHUB_URL_PATTERN = /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+)\/([^/]+?)(?:\.git)?$/i;

// =============================================================================
// Error Types
// =============================================================================

class InvalidUrlError extends RpcError {
  constructor(message: string) {
    super('INVALID_URL' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class AlreadyExistsError extends RpcError {
  constructor(message: string) {
    super('ALREADY_EXISTS' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class ParentNotFoundError extends RpcError {
  constructor(message: string) {
    super('PARENT_NOT_FOUND' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class CloneFailedError extends RpcError {
  constructor(message: string) {
    super('CLONE_FAILED' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Validate and parse a GitHub URL
 * Returns the normalized HTTPS URL and repo name, or null if invalid
 */
function parseGitHubUrl(url: string): { normalizedUrl: string; owner: string; repoName: string } | null {
  const trimmedUrl = url.trim();
  const match = trimmedUrl.match(GITHUB_URL_PATTERN);

  if (!match) {
    return null;
  }

  const owner = match[1];
  const repoName = match[2];
  if (!owner || !repoName) {
    return null;
  }
  // Remove .git suffix if present for the repo name
  const cleanRepoName = repoName.replace(/\.git$/i, '');
  // Always use HTTPS URL for cloning
  const normalizedUrl = `https://github.com/${owner}/${cleanRepoName}.git`;

  return { normalizedUrl, owner, repoName: cleanRepoName };
}

/**
 * Execute git clone command
 */
async function executeGitClone(
  url: string,
  targetPath: string,
  timeoutMs: number
): Promise<{ success: boolean; error?: string }> {
  return new Promise((resolve) => {
    const proc = spawn('git', ['clone', '--depth', '1', url, targetPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: timeoutMs,
    });

    let stderr = '';
    let stdout = '';

    proc.stdout?.on('data', (data) => {
      stdout += data.toString();
    });

    proc.stderr?.on('data', (data) => {
      stderr += data.toString();
    });

    proc.on('error', (err) => {
      resolve({ success: false, error: `Failed to spawn git: ${err.message}` });
    });

    proc.on('close', (code) => {
      if (code === 0) {
        resolve({ success: true });
      } else {
        // Git outputs progress to stderr, so extract actual error
        const errorMsg = stderr.trim() || stdout.trim() || `Git exited with code ${code}`;
        resolve({ success: false, error: errorMsg });
      }
    });

    // Handle timeout
    setTimeout(() => {
      proc.kill('SIGTERM');
      resolve({ success: false, error: 'Clone timed out. Try again or use a smaller repository.' });
    }, timeoutMs);
  });
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create git handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createGitHandlers(): MethodRegistration[] {
  const cloneHandler: MethodHandler<GitCloneParams> = async (request) => {
    const params = request.params!;  // Validated by registry via requiredParams

    // Parse and validate GitHub URL
    const parsed = parseGitHubUrl(params.url);
    if (!parsed) {
      throw new InvalidUrlError('Enter a valid GitHub URL (e.g., github.com/owner/repo)');
    }

    const { normalizedUrl, repoName } = parsed;
    const targetPath = path.resolve(params.targetPath);

    // Security: Reject path traversal
    if (params.targetPath.includes('..')) {
      throw new InvalidParamsError('Path traversal not allowed');
    }

    // Check if target already exists
    try {
      await fs.access(targetPath);
      throw new AlreadyExistsError('Folder already exists. Choose a different name.');
    } catch (error) {
      // Re-throw our typed errors
      if (error instanceof RpcError) {
        throw error;
      }
      // Path doesn't exist - good, continue
    }

    // Ensure parent directory exists
    const parentDir = path.dirname(targetPath);
    try {
      await fs.access(parentDir);
    } catch {
      // Try to create parent directory
      try {
        await fs.mkdir(parentDir, { recursive: true });
      } catch {
        throw new ParentNotFoundError(`Parent directory does not exist and could not be created: ${parentDir}`);
      }
    }

    // Execute clone
    const cloneResult = await executeGitClone(normalizedUrl, targetPath, CLONE_TIMEOUT_MS);

    if (!cloneResult.success) {
      // Clean error message for common cases
      let errorMessage = cloneResult.error || 'Clone failed';

      if (errorMessage.includes('Repository not found')) {
        errorMessage = 'Repository not found. Check the URL and ensure the repo is public.';
      } else if (errorMessage.includes('Could not resolve host')) {
        errorMessage = 'Network error. Check your connection.';
      } else if (errorMessage.includes('Authentication failed')) {
        errorMessage = 'Authentication failed. This may be a private repository.';
      }

      throw new CloneFailedError(errorMessage);
    }

    const result: GitCloneResult = {
      success: true,
      path: targetPath,
      repoName,
    };

    return result;
  };

  return [
    {
      method: 'git.clone',
      handler: cloneHandler,
      options: {
        requiredParams: ['url', 'targetPath'],
        description: 'Clone a Git repository',
      },
    },
  ];
}
