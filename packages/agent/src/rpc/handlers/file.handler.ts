/**
 * @fileoverview File RPC Handlers
 *
 * Handlers for file.* RPC methods:
 * - file.read: Read a file from the filesystem
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

interface FileReadParams {
  path: string;
}

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle file.read request
 *
 * Reads a file from the filesystem.
 * Security: Only allows reading files within the home directory.
 */
export async function handleFileRead(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as FileReadParams | undefined;

  if (!params?.path) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'path is required');
  }

  const filePath = params.path;
  const homeDir = os.homedir();

  // Normalize path to prevent directory traversal attacks
  const normalizedPath = path.normalize(filePath);

  // Only allow absolute paths that are within safe directories
  if (!normalizedPath.startsWith(homeDir)) {
    return MethodRegistry.errorResponse(
      request.id,
      'PERMISSION_DENIED',
      'Can only read files within home directory'
    );
  }

  try {
    const content = await fs.readFile(normalizedPath, 'utf-8');
    return MethodRegistry.successResponse(request.id, { content });
  } catch (error) {
    if (error instanceof Error && 'code' in error && (error as NodeJS.ErrnoException).code === 'ENOENT') {
      return MethodRegistry.errorResponse(request.id, 'FILE_NOT_FOUND', 'File not found');
    }
    const message = error instanceof Error ? error.message : 'Failed to read file';
    return MethodRegistry.errorResponse(request.id, 'FILE_ERROR', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create file handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createFileHandlers(): MethodRegistration[] {
  const readHandler: MethodHandler = async (request, context) => {
    const response = await handleFileRead(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'file.read',
      handler: readHandler,
      options: {
        requiredParams: ['path'],
        description: 'Read a file from the filesystem',
      },
    },
  ];
}
