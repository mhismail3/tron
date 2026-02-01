/**
 * @fileoverview Filesystem domain - File operations
 *
 * Groups file, filesystem, and git handlers into a single domain.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// File handlers
export {
  handleFileRead,
  createFileHandlers,
} from '../../../../rpc/handlers/file.handler.js';

// Filesystem handlers
export {
  handleFilesystemListDir,
  handleFilesystemGetHome,
  handleFilesystemCreateDir,
  createFilesystemHandlers,
} from '../../../../rpc/handlers/filesystem.handler.js';

// Git handlers
export {
  handleGitClone,
  createGitHandlers,
} from '../../../../rpc/handlers/git.handler.js';

// Re-export types
export type {
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeResult,
  FilesystemCreateDirParams,
  FilesystemCreateDirResult,
} from '../../../../rpc/types/filesystem.js';

export type {
  GitCloneParams,
  GitCloneResult,
} from '../../../../rpc/types/git.js';
