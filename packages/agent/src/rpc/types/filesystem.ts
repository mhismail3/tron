/**
 * @fileoverview Filesystem RPC Types
 *
 * Types for filesystem operations methods.
 */

// =============================================================================
// Filesystem Methods
// =============================================================================

/** List directory contents */
export interface FilesystemListDirParams {
  /** Path to list (defaults to home directory if not specified) */
  path?: string;
  /** Include hidden files (starting with .) */
  showHidden?: boolean;
}

export interface FilesystemListDirResult {
  /** Current directory path (absolute) */
  path: string;
  /** Parent directory path (null if at root) */
  parent: string | null;
  /** Directory entries */
  entries: Array<{
    /** Entry name */
    name: string;
    /** Full path */
    path: string;
    /** Whether this is a directory */
    isDirectory: boolean;
    /** Whether this is a symbolic link */
    isSymlink?: boolean;
    /** File size in bytes (files only) */
    size?: number;
    /** Last modified timestamp */
    modifiedAt?: string;
  }>;
}

/** Get home directory */
export interface FilesystemGetHomeParams {}

export interface FilesystemGetHomeResult {
  /** User's home directory path */
  homePath: string;
  /** Common project directories */
  suggestedPaths: Array<{
    name: string;
    path: string;
    exists: boolean;
  }>;
}

/** Create directory */
export interface FilesystemCreateDirParams {
  /** Path of the directory to create */
  path: string;
  /** Whether to create parent directories if they don't exist (default: false) */
  recursive?: boolean;
}

export interface FilesystemCreateDirResult {
  /** Whether the directory was created successfully */
  created: boolean;
  /** The absolute path of the created directory */
  path: string;
}

// =============================================================================
// File Read Methods
// =============================================================================

/** Read file contents */
export interface FileReadParams {
  /** Absolute path to the file to read */
  path: string;
  /** Optional encoding (defaults to utf8) */
  encoding?: string;
  /** Maximum bytes to read (for large files) */
  maxBytes?: number;
}

export interface FileReadResult {
  /** File contents */
  content: string;
  /** Whether the file was truncated */
  truncated: boolean;
  /** Total file size in bytes */
  size: number;
  /** File MIME type */
  mimeType?: string;
}
