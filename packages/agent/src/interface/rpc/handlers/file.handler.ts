/**
 * @fileoverview File RPC Handlers
 *
 * Handlers for file.* RPC methods:
 * - file.read: Read a file from the filesystem
 *
 * Validation is handled by the registry via requiredParams options.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { FileNotFoundError, FileError, PermissionDeniedError } from './base.js';

// =============================================================================
// Types
// =============================================================================

interface FileReadParams {
  path: string;
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
  const readHandler: MethodHandler<FileReadParams> = async (request) => {
    const params = request.params!;
    const filePath = params.path;
    const homeDir = os.homedir();

    // Normalize path to prevent directory traversal attacks
    const normalizedPath = path.normalize(filePath);

    // Only allow absolute paths that are within safe directories
    if (!normalizedPath.startsWith(homeDir)) {
      throw new PermissionDeniedError('Can only read files within home directory');
    }

    try {
      const content = await fs.readFile(normalizedPath, 'utf-8');
      return { content };
    } catch (error) {
      if (error instanceof Error && 'code' in error && (error as NodeJS.ErrnoException).code === 'ENOENT') {
        throw new FileNotFoundError(normalizedPath);
      }
      const message = error instanceof Error ? error.message : 'Failed to read file';
      throw new FileError(message);
    }
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
