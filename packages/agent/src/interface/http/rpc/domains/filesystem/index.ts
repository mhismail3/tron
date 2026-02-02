/**
 * @fileoverview Filesystem domain - File operations
 *
 * Groups file, filesystem, and git handlers into a single domain.
 */

// File handlers
export { createFileHandlers } from '@interface/rpc/handlers/file.handler.js';

// Filesystem handlers
export { createFilesystemHandlers } from '@interface/rpc/handlers/filesystem.handler.js';

// Git handlers
export { createGitHandlers } from '@interface/rpc/handlers/git.handler.js';

// Re-export types
export type {
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeResult,
  FilesystemCreateDirParams,
  FilesystemCreateDirResult,
} from '@interface/rpc/types/filesystem.js';

export type {
  GitCloneParams,
  GitCloneResult,
} from '@interface/rpc/types/git.js';
