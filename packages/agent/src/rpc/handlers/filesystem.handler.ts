/**
 * @fileoverview Filesystem RPC Handlers
 *
 * Handlers for filesystem.* RPC methods:
 * - filesystem.listDir: List directory contents
 * - filesystem.getHome: Get home directory and suggested paths
 * - filesystem.createDir: Create a new directory
 *
 * These handlers interact directly with the filesystem via Node.js fs module.
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import { RpcHandlerError } from '../../utils/index.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type {
  RpcRequest,
  RpcResponse,
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeResult,
  FilesystemCreateDirParams,
  FilesystemCreateDirResult,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:filesystem');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle filesystem.listDir request
 *
 * Lists directory contents with optional hidden file filtering.
 * Returns sorted entries (directories first, then alphabetically).
 */
export async function handleFilesystemListDir(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const params = (request.params || {}) as FilesystemListDirParams;

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

    return MethodRegistry.successResponse(request.id, result);
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
    return MethodRegistry.errorResponse(request.id, 'FILESYSTEM_ERROR', message);
  }
}

/**
 * Handle filesystem.getHome request
 *
 * Returns home directory path and suggests common project directories.
 */
export async function handleFilesystemGetHome(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
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

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle filesystem.createDir request
 *
 * Creates a new directory with validation:
 * - Rejects path traversal (.. sequences)
 * - Rejects hidden folders (starting with .)
 * - Rejects invalid characters
 * - Supports recursive creation
 */
export async function handleFilesystemCreateDir(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as FilesystemCreateDirParams | undefined;

  // Validate path parameter
  if (!params?.path) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'path is required');
  }

  const inputPath = params.path.trim();
  if (!inputPath) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'path is required');
  }

  // Reject path traversal attempts before normalization
  if (inputPath.includes('..')) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'Path traversal not allowed');
  }

  // Normalize path
  const normalizedPath = path.normalize(inputPath);

  // Validate folder name
  const folderName = path.basename(normalizedPath);
  if (!folderName) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'Invalid folder name');
  }

  // Reject hidden folder names (starting with .)
  if (folderName.startsWith('.')) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'Hidden folders not allowed');
  }

  // Check for reserved/invalid characters (cross-platform safety)
  const invalidChars = /[<>:"|?*\x00-\x1f]/;
  if (invalidChars.test(folderName)) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'Folder name contains invalid characters');
  }

  try {
    const resolvedPath = path.resolve(normalizedPath);

    // Check if path already exists
    try {
      const stat = await fs.stat(resolvedPath);
      if (stat.isDirectory()) {
        return MethodRegistry.errorResponse(request.id, 'ALREADY_EXISTS', 'Directory already exists');
      } else {
        return MethodRegistry.errorResponse(request.id, 'INVALID_PATH', 'Path exists but is not a directory');
      }
    } catch {
      // Path doesn't exist - this is expected, continue with creation
    }

    // Create the directory
    await fs.mkdir(resolvedPath, { recursive: params.recursive ?? false });

    const result: FilesystemCreateDirResult = {
      created: true,
      path: resolvedPath,
    };

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to create directory';

    // Map common error codes to user-friendly error codes
    if (error instanceof Error && 'code' in error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === 'EACCES') {
        return MethodRegistry.errorResponse(request.id, 'PERMISSION_DENIED', 'Permission denied');
      }
      if (code === 'ENOENT') {
        return MethodRegistry.errorResponse(request.id, 'PARENT_NOT_FOUND', 'Parent directory does not exist');
      }
      if (code === 'EEXIST') {
        return MethodRegistry.errorResponse(request.id, 'ALREADY_EXISTS', 'Directory already exists');
      }
    }

    const structured = categorizeError(error, { path: inputPath, operation: 'createDir' });
    logger.error('Failed to create directory', {
      path: inputPath,
      code: structured.code,
      category: LogErrorCategory.FILESYSTEM,
      error: structured.message,
      retryable: structured.retryable,
    });
    return MethodRegistry.errorResponse(request.id, 'FILESYSTEM_ERROR', message);
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
  const listDirHandler: MethodHandler = async (request, context) => {
    const response = await handleFilesystemListDir(request, context);
    // Extract result from response (registry will wrap again)
    if (response.success && response.result) {
      return response.result;
    }
    // For errors, throw to let registry handle
    throw RpcHandlerError.fromResponse(response);
  };

  const getHomeHandler: MethodHandler = async (request, context) => {
    const response = await handleFilesystemGetHome(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const createDirHandler: MethodHandler = async (request, context) => {
    const response = await handleFilesystemCreateDir(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    // Re-throw with original error code info
    throw RpcHandlerError.fromResponse(response);
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
