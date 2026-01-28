/**
 * @fileoverview Type-safe mock factories for Node.js fs module types
 *
 * Provides properly typed mocks for fs.Stats, fs.Dirent, and NodeJS.ErrnoException
 * to eliminate unsafe `as any` casts in test files.
 *
 * @example
 * ```typescript
 * import { createMockStats, createMockDirent, createFsError } from '../__fixtures__/mocks/fs.js';
 *
 * vi.mocked(fs.stat).mockResolvedValue(createMockStats({ size: 1024 }));
 * vi.mocked(fs.readdir).mockResolvedValue([createMockDirent('file.ts', { isFile: true })]);
 * vi.mocked(fs.readFile).mockRejectedValue(createFsError('ENOENT', 'File not found'));
 * ```
 */

import type { Stats, Dirent } from 'fs';

/**
 * Options for creating mock fs.Stats
 */
export interface MockStatsOptions {
  /** Whether the target is a directory */
  isDirectory?: boolean;
  /** Whether the target is a file */
  isFile?: boolean;
  /** Whether the target is a symbolic link */
  isSymbolicLink?: boolean;
  /** Whether the target is a block device */
  isBlockDevice?: boolean;
  /** Whether the target is a character device */
  isCharacterDevice?: boolean;
  /** Whether the target is a FIFO */
  isFIFO?: boolean;
  /** Whether the target is a socket */
  isSocket?: boolean;
  /** File size in bytes */
  size?: number;
  /** File mode (permissions) */
  mode?: number;
  /** User ID of owner */
  uid?: number;
  /** Group ID of owner */
  gid?: number;
  /** Number of hard links */
  nlink?: number;
  /** Device ID */
  dev?: number;
  /** Inode number */
  ino?: number;
  /** Device ID for special files */
  rdev?: number;
  /** Block size for file system I/O */
  blksize?: number;
  /** Number of blocks allocated */
  blocks?: number;
  /** Last access time */
  atime?: Date;
  /** Last modification time */
  mtime?: Date;
  /** Last status change time */
  ctime?: Date;
  /** Creation time (birth time) */
  birthtime?: Date;
}

/**
 * Create a properly typed mock fs.Stats object
 *
 * @param options - Options for the mock Stats object
 * @returns A fully typed Stats object suitable for mocking fs.stat() calls
 */
export function createMockStats(options: MockStatsOptions = {}): Stats {
  const now = new Date();
  const isDir = options.isDirectory ?? false;
  const isFile = options.isFile ?? !isDir;

  const stats: Stats = {
    isFile: () => isFile,
    isDirectory: () => isDir,
    isSymbolicLink: () => options.isSymbolicLink ?? false,
    isBlockDevice: () => options.isBlockDevice ?? false,
    isCharacterDevice: () => options.isCharacterDevice ?? false,
    isFIFO: () => options.isFIFO ?? false,
    isSocket: () => options.isSocket ?? false,
    dev: options.dev ?? 0,
    ino: options.ino ?? 0,
    mode: options.mode ?? (isDir ? 0o755 : 0o644),
    nlink: options.nlink ?? 1,
    uid: options.uid ?? 0,
    gid: options.gid ?? 0,
    rdev: options.rdev ?? 0,
    size: options.size ?? 0,
    blksize: options.blksize ?? 4096,
    blocks: options.blocks ?? 0,
    atimeMs: (options.atime ?? now).getTime(),
    mtimeMs: (options.mtime ?? now).getTime(),
    ctimeMs: (options.ctime ?? now).getTime(),
    birthtimeMs: (options.birthtime ?? now).getTime(),
    atime: options.atime ?? now,
    mtime: options.mtime ?? now,
    ctime: options.ctime ?? now,
    birthtime: options.birthtime ?? now,
  };

  return stats;
}

/**
 * Options for creating mock fs.Dirent
 */
export interface MockDirentOptions {
  /** Whether the entry is a directory */
  isDirectory?: boolean;
  /** Whether the entry is a file */
  isFile?: boolean;
  /** Whether the entry is a symbolic link */
  isSymbolicLink?: boolean;
  /** Whether the entry is a block device */
  isBlockDevice?: boolean;
  /** Whether the entry is a character device */
  isCharacterDevice?: boolean;
  /** Whether the entry is a FIFO */
  isFIFO?: boolean;
  /** Whether the entry is a socket */
  isSocket?: boolean;
  /** Parent path (for path property) */
  parentPath?: string;
}

/**
 * Create a properly typed mock fs.Dirent object
 *
 * @param name - The name of the directory entry
 * @param options - Options for the mock Dirent object
 * @returns A fully typed Dirent object suitable for mocking fs.readdir() calls
 */
export function createMockDirent(name: string, options: MockDirentOptions = {}): Dirent {
  const isDir = options.isDirectory ?? false;
  const isFile = options.isFile ?? !isDir;

  const dirent: Dirent = {
    name,
    parentPath: options.parentPath ?? '',
    path: options.parentPath ?? '',
    isFile: () => isFile,
    isDirectory: () => isDir,
    isSymbolicLink: () => options.isSymbolicLink ?? false,
    isBlockDevice: () => options.isBlockDevice ?? false,
    isCharacterDevice: () => options.isCharacterDevice ?? false,
    isFIFO: () => options.isFIFO ?? false,
    isSocket: () => options.isSocket ?? false,
  };

  return dirent;
}

/**
 * Common error codes for fs operations
 */
export type FsErrorCode =
  | 'ENOENT'    // No such file or directory
  | 'EACCES'    // Permission denied
  | 'EEXIST'    // File exists
  | 'EISDIR'    // Is a directory
  | 'ENOTDIR'   // Not a directory
  | 'ENOTEMPTY' // Directory not empty
  | 'EBUSY'     // Resource busy
  | 'EMFILE'    // Too many open files
  | 'ENFILE'    // File table overflow
  | 'EPERM'     // Operation not permitted
  | 'EROFS'     // Read-only file system
  | 'ENOSPC'    // No space left on device
  | 'ENAMETOOLONG'; // File name too long

/**
 * Create a properly typed Node.js fs error (ErrnoException)
 *
 * @param code - The error code (e.g., 'ENOENT', 'EACCES')
 * @param message - The error message
 * @param path - Optional path that caused the error
 * @param syscall - Optional system call that failed (e.g., 'open', 'read')
 * @returns A properly typed Error with errno properties
 */
export function createFsError(
  code: FsErrorCode,
  message?: string,
  path?: string,
  syscall?: string
): NodeJS.ErrnoException {
  const defaultMessages: Record<FsErrorCode, string> = {
    ENOENT: 'no such file or directory',
    EACCES: 'permission denied',
    EEXIST: 'file already exists',
    EISDIR: 'illegal operation on a directory',
    ENOTDIR: 'not a directory',
    ENOTEMPTY: 'directory not empty',
    EBUSY: 'resource busy or locked',
    EMFILE: 'too many open files',
    ENFILE: 'file table overflow',
    EPERM: 'operation not permitted',
    EROFS: 'read-only file system',
    ENOSPC: 'no space left on device',
    ENAMETOOLONG: 'file name too long',
  };

  const errnoMap: Record<FsErrorCode, number> = {
    ENOENT: -2,
    EACCES: -13,
    EEXIST: -17,
    EISDIR: -21,
    ENOTDIR: -20,
    ENOTEMPTY: -39,
    EBUSY: -16,
    EMFILE: -24,
    ENFILE: -23,
    EPERM: -1,
    EROFS: -30,
    ENOSPC: -28,
    ENAMETOOLONG: -36,
  };

  const fullMessage = message ?? defaultMessages[code];
  const errorMessage = path
    ? `${code}: ${fullMessage}, ${syscall ?? 'access'} '${path}'`
    : `${code}: ${fullMessage}`;

  const error = new Error(errorMessage) as NodeJS.ErrnoException;
  error.code = code;
  error.errno = errnoMap[code];
  error.syscall = syscall;
  error.path = path;

  return error;
}

/**
 * Create an array of mock Dirent objects for directory listing
 *
 * @param entries - Array of [name, options] tuples
 * @returns Array of properly typed Dirent objects
 */
export function createMockDirents(
  entries: Array<[string, MockDirentOptions?]>
): Dirent[] {
  return entries.map(([name, opts]) => createMockDirent(name, opts));
}
