/**
 * @fileoverview Filesystem RPC Handlers
 *
 * Handlers for filesystem.* RPC methods:
 * - filesystem.listDir: List directory contents
 * - filesystem.getHome: Get home directory and suggested paths
 * - filesystem.createDir: Create a new directory
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type {
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeResult,
  FilesystemCreateDirParams,
  FilesystemCreateDirResult,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode, InvalidParamsError, PermissionDeniedError } from './base.js';

const logger = createLogger('rpc:filesystem');

// =============================================================================
// Error Types
// =============================================================================

class FilesystemError extends RpcError {
  constructor(message: string) {
    super('FILESYSTEM_ERROR' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class AlreadyExistsError extends RpcError {
  constructor(message: string) {
    super('ALREADY_EXISTS' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class InvalidPathError extends RpcError {
  constructor(message: string) {
    super('INVALID_PATH' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class ParentNotFoundError extends RpcError {
  constructor(message: string) {
    super('PARENT_NOT_FOUND' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create filesystem handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createFilesystemHandlers(): MethodRegistration[] {
  const listDirHandler: MethodHandler<FilesystemListDirParams> = async (request) => {
    const params = request.params ?? {};

    // Default to home directory if no path specified
    const targetPath = params.path || os.homedir();
    const showHidden = params.showHidden ?? false;

    try {
      // Resolve to absolute path and normalize
      const resolvedPath = path.resolve(targetPath);

      // Read directory entries
      const dirents = await fs.readdir(resolvedPath, { withFileTypes: true });

      // Filter and map entries
      const entries: FilesystemListDirResult['entries'] = [];

      for (const dirent of dirents) {
        // Skip hidden files unless requested
        if (!showHidden && dirent.name.startsWith('.')) {
          continue;
        }

        const entryPath = path.join(resolvedPath, dirent.name);
        const isDirectory = dirent.isDirectory();
        const isSymlink = dirent.isSymbolicLink();

        let size: number | undefined;
        let modifiedAt: string | undefined;

        // Only get stats for non-directories (to avoid permission errors on system dirs)
        if (!isDirectory) {
          try {
            const stats = await fs.stat(entryPath);
            size = stats.size;
            modifiedAt = stats.mtime.toISOString();
          } catch {
            // Skip if we can't read stats
          }
        }

        entries.push({
          name: dirent.name,
          path: entryPath,
          isDirectory,
          isSymlink,
          size,
          modifiedAt,
        });
      }

      // Sort: directories first, then alphabetically
      entries.sort((a, b) => {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
      });

      // Get parent path
      const parent = resolvedPath === path.parse(resolvedPath).root
        ? null
        : path.dirname(resolvedPath);

      const result: FilesystemListDirResult = {
        path: resolvedPath,
        parent,
        entries,
      };

      return result;
    } catch (error) {
      const structured = categorizeError(error, { path: targetPath, operation: 'listDir' });
      logger.error('Failed to list directory', {
        path: targetPath,
        code: structured.code,
        category: LogErrorCategory.FILESYSTEM,
        error: structured.message,
        retryable: structured.retryable,
      });
      const message = error instanceof Error ? error.message : 'Failed to list directory';
      throw new FilesystemError(message);
    }
  };

  const getHomeHandler: MethodHandler = async () => {
    const homePath = os.homedir();

    // Common project directories to suggest
    const commonPaths = [
      { name: 'Home', path: homePath },
      { name: 'Desktop', path: path.join(homePath, 'Desktop') },
      { name: 'Documents', path: path.join(homePath, 'Documents') },
      { name: 'Downloads', path: path.join(homePath, 'Downloads') },
      { name: 'Projects', path: path.join(homePath, 'projects') },
      { name: 'Code', path: path.join(homePath, 'code') },
      { name: 'Development', path: path.join(homePath, 'Development') },
      { name: 'dev', path: path.join(homePath, 'dev') },
      { name: 'src', path: path.join(homePath, 'src') },
      { name: 'workspace', path: path.join(homePath, 'workspace') },
      { name: 'work', path: path.join(homePath, 'work') },
    ];

    // Check which paths exist
    const suggestedPaths = await Promise.all(
      commonPaths.map(async ({ name, path: dirPath }) => {
        try {
          const stat = await fs.stat(dirPath);
          return { name, path: dirPath, exists: stat.isDirectory() };
        } catch {
          return { name, path: dirPath, exists: false };
        }
      })
    );

    // Filter to only existing paths, but always include home
    const existingPaths = suggestedPaths.filter(p => p.exists || p.path === homePath);

    const result: FilesystemGetHomeResult = {
      homePath,
      suggestedPaths: existingPaths,
    };

    return result;
  };

  const createDirHandler: MethodHandler<FilesystemCreateDirParams> = async (request) => {
    const params = request.params!;  // Validated by registry via requiredParams

    const inputPath = params.path.trim();
    if (!inputPath) {
      throw new InvalidParamsError('path is required');
    }

    // Reject path traversal attempts before normalization
    if (inputPath.includes('..')) {
      throw new InvalidParamsError('Path traversal not allowed');
    }

    // Normalize path
    const normalizedPath = path.normalize(inputPath);

    // Validate folder name
    const folderName = path.basename(normalizedPath);
    if (!folderName) {
      throw new InvalidParamsError('Invalid folder name');
    }

    // Reject hidden folder names (starting with .)
    if (folderName.startsWith('.')) {
      throw new InvalidParamsError('Hidden folders not allowed');
    }

    // Check for reserved/invalid characters (cross-platform safety)
    const invalidChars = /[<>:"|?*\x00-\x1f]/;
    if (invalidChars.test(folderName)) {
      throw new InvalidParamsError('Folder name contains invalid characters');
    }

    try {
      const resolvedPath = path.resolve(normalizedPath);

      // Check if path already exists
      try {
        const stat = await fs.stat(resolvedPath);
        if (stat.isDirectory()) {
          throw new AlreadyExistsError('Directory already exists');
        } else {
          throw new InvalidPathError('Path exists but is not a directory');
        }
      } catch (error) {
        // Re-throw our typed errors
        if (error instanceof RpcError) {
          throw error;
        }
        // Path doesn't exist - this is expected, continue with creation
      }

      // Create the directory
      await fs.mkdir(resolvedPath, { recursive: params.recursive ?? false });

      const result: FilesystemCreateDirResult = {
        created: true,
        path: resolvedPath,
      };

      return result;
    } catch (error) {
      // Re-throw typed errors
      if (error instanceof RpcError) {
        throw error;
      }

      // Map common error codes to user-friendly errors
      if (error instanceof Error && 'code' in error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === 'EACCES') {
          throw new PermissionDeniedError('Permission denied');
        }
        if (code === 'ENOENT') {
          throw new ParentNotFoundError('Parent directory does not exist');
        }
        if (code === 'EEXIST') {
          throw new AlreadyExistsError('Directory already exists');
        }
      }

      const message = error instanceof Error ? error.message : 'Failed to create directory';
      const structured = categorizeError(error, { path: inputPath, operation: 'createDir' });
      logger.error('Failed to create directory', {
        path: inputPath,
        code: structured.code,
        category: LogErrorCategory.FILESYSTEM,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw new FilesystemError(message);
    }
  };

  return [
    {
      method: 'filesystem.listDir',
      handler: listDirHandler,
      options: {
        description: 'List directory contents',
      },
    },
    {
      method: 'filesystem.getHome',
      handler: getHomeHandler,
      options: {
        description: 'Get home directory and suggested paths',
      },
    },
    {
      method: 'filesystem.createDir',
      handler: createDirHandler,
      options: {
        requiredParams: ['path'],
        description: 'Create a new directory',
      },
    },
  ];
}
