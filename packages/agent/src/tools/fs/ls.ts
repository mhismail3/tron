/**
 * @fileoverview Ls tool for directory listing
 *
 * Lists directory contents with support for long format,
 * hidden files, and various sorting options.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger, categorizeError } from '../../logging/index.js';
import { getSettings } from '../../settings/index.js';
import {
  truncateOutput,
  resolvePath,
  formatFsError,
} from '../utils.js';

const logger = createLogger('tool:ls');

// Get ls tool settings (loaded lazily on first access)
function getLsSettings() {
  return getSettings().tools.ls ?? { maxEntries: 1000, maxOutputTokens: 10000 };
}

export interface LsToolConfig {
  workingDirectory: string;
}

interface LsEntry {
  name: string;
  isDirectory: boolean;
  isFile: boolean;
  isSymlink: boolean;
  size?: number;
  mtime?: Date;
  target?: string; // For symlinks
}

export class LsTool implements TronTool {
  readonly name = 'Ls';
  readonly description = 'List directory contents. Shows files and subdirectories with optional details.';
  readonly category = 'filesystem' as const;
  readonly parameters = {
    type: 'object' as const,
    properties: {
      path: {
        type: 'string' as const,
        description: 'Directory path to list (defaults to current directory)',
      },
      all: {
        type: 'boolean' as const,
        description: 'Show hidden files (starting with .)',
      },
      long: {
        type: 'boolean' as const,
        description: 'Long format with sizes and dates',
      },
      humanReadable: {
        type: 'boolean' as const,
        description: 'Human-readable file sizes (requires long format)',
      },
      groupDirectoriesFirst: {
        type: 'boolean' as const,
        description: 'Show directories before files',
      },
    },
    required: [] as string[],
  };

  private config: LsToolConfig;

  constructor(config: LsToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate path if provided
    const rawPath = args.path as string | undefined;
    if (rawPath !== undefined && typeof rawPath !== 'string') {
      return {
        content: 'Invalid path parameter: path must be a string. Example: "." or "/home/user/project"',
        isError: true,
        details: { path: rawPath },
      };
    }

    const listPath = resolvePath(rawPath || '.', this.config.workingDirectory);
    const showAll = (args.all as boolean) ?? false;
    const longFormat = (args.long as boolean) ?? false;
    const humanReadable = (args.humanReadable as boolean) ?? false;
    const groupDirsFirst = (args.groupDirectoriesFirst as boolean) ?? false;

    logger.debug('Ls', { listPath, showAll, longFormat });

    try {
      const stat = await fs.stat(listPath);

      // If it's a file, just show info about that file
      if (stat.isFile()) {
        const entry = await this.getFileEntry(listPath, path.basename(listPath));
        const output = longFormat
          ? this.formatLongEntry(entry, humanReadable)
          : entry.name;

        return {
          content: output,
          isError: false,
          details: {
            path: listPath,
            entryCount: 1,
            fileCount: 1,
            dirCount: 0,
          },
        };
      }

      if (!stat.isDirectory()) {
        return {
          content: `Not a file or directory: ${listPath}`,
          isError: true,
          details: { path: listPath },
        };
      }

      const settings = getLsSettings();
      const maxEntries = settings.maxEntries ?? 1000;
      const maxOutputTokens = settings.maxOutputTokens ?? 10000;

      const dirEntries = await fs.readdir(listPath, { withFileTypes: true });
      const entries: LsEntry[] = [];
      let entriesTruncated = false;
      let totalEntryCount = 0;

      for (const dirent of dirEntries) {
        // Skip hidden files unless showAll
        if (!showAll && dirent.name.startsWith('.')) {
          continue;
        }

        totalEntryCount++;

        // Stop collecting if we hit the entry limit
        if (entries.length >= maxEntries) {
          entriesTruncated = true;
          continue; // Continue counting total entries
        }

        const fullPath = path.join(listPath, dirent.name);
        const entry = await this.getEntryInfo(fullPath, dirent);
        entries.push(entry);
      }

      if (entries.length === 0) {
        return {
          content: '(empty directory)',
          isError: false,
          details: {
            path: listPath,
            entryCount: 0,
            fileCount: 0,
            dirCount: 0,
          },
        };
      }

      // Sort entries
      this.sortEntries(entries, groupDirsFirst);

      // Format output
      let output = longFormat
        ? this.formatLong(entries, humanReadable)
        : this.formatSimple(entries);

      // Add entry truncation message if needed
      if (entriesTruncated) {
        output += `\n\n... [Showing ${entries.length} of ${totalEntryCount} entries]`;
      }

      // Apply token-based truncation
      const truncateResult = truncateOutput(output, maxOutputTokens, {
        preserveStartLines: 20,
        truncationMessage: entriesTruncated
          ? `\n\n... [Showing ${entries.length} of ${totalEntryCount} entries, output also truncated for token limit]`
          : `\n\n... [Output truncated: exceeded ${maxOutputTokens.toLocaleString()} token limit]`,
      });

      const fileCount = entries.filter(e => e.isFile).length;
      const dirCount = entries.filter(e => e.isDirectory).length;

      logger.debug('Ls completed', {
        path: listPath,
        entryCount: entries.length,
        totalEntryCount,
        truncated: entriesTruncated || truncateResult.truncated,
      });

      return {
        content: truncateResult.content,
        isError: false,
        details: {
          path: listPath,
          entryCount: entries.length,
          totalEntryCount,
          fileCount,
          dirCount,
          truncated: entriesTruncated || truncateResult.truncated,
          ...(truncateResult.truncated && {
            originalTokens: truncateResult.originalTokens,
            finalTokens: truncateResult.finalTokens,
          }),
        },
      };
    } catch (error) {
      const structured = categorizeError(error, { path: listPath, operation: 'ls' });
      logger.error('Ls failed', {
        path: listPath,
        error: structured.message,
        code: structured.code,
        category: structured.category,
      });
      return formatFsError(error, listPath, 'listing');
    }
  }

  private async getEntryInfo(
    fullPath: string,
    dirent: { name: string; isDirectory: () => boolean; isFile: () => boolean; isSymbolicLink: () => boolean }
  ): Promise<LsEntry> {
    const entry: LsEntry = {
      name: dirent.name,
      isDirectory: dirent.isDirectory(),
      isFile: dirent.isFile(),
      isSymlink: dirent.isSymbolicLink(),
    };

    try {
      const stat = await fs.stat(fullPath);
      entry.size = stat.size;
      entry.mtime = stat.mtime;

      if (entry.isSymlink) {
        entry.target = await fs.readlink(fullPath);
      }
    } catch {
      // Ignore stat errors (broken symlinks, etc.)
    }

    return entry;
  }

  private async getFileEntry(fullPath: string, name: string): Promise<LsEntry> {
    const stat = await fs.stat(fullPath);
    const lstat = await fs.lstat(fullPath);

    return {
      name,
      isDirectory: stat.isDirectory(),
      isFile: stat.isFile(),
      isSymlink: lstat.isSymbolicLink(),
      size: stat.size,
      mtime: stat.mtime,
    };
  }

  private sortEntries(entries: LsEntry[], groupDirsFirst: boolean): void {
    entries.sort((a, b) => {
      // If grouping directories first
      if (groupDirsFirst) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
      }
      // Then alphabetically (case-insensitive)
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    });
  }

  private formatSimple(entries: LsEntry[]): string {
    return entries
      .map(e => {
        if (e.isDirectory) {
          return `${e.name}/`;
        } else if (e.isSymlink) {
          return `${e.name}@`;
        }
        return e.name;
      })
      .join('\n');
  }

  private formatLong(entries: LsEntry[], humanReadable: boolean): string {
    const lines: string[] = [];

    for (const entry of entries) {
      lines.push(this.formatLongEntry(entry, humanReadable));
    }

    return lines.join('\n');
  }

  private formatLongEntry(entry: LsEntry, humanReadable: boolean): string {
    const parts: string[] = [];

    // Type indicator
    if (entry.isDirectory) {
      parts.push('[D]');
    } else if (entry.isSymlink) {
      parts.push('[L]');
    } else {
      parts.push('[F]');
    }

    // Size
    if (entry.size !== undefined) {
      const sizeStr = humanReadable
        ? this.formatHumanSize(entry.size)
        : String(entry.size);
      parts.push(sizeStr.padStart(10));
    } else {
      parts.push('-'.padStart(10));
    }

    // Modified time
    if (entry.mtime) {
      parts.push(this.formatDate(entry.mtime));
    } else {
      parts.push('-'.padStart(16));
    }

    // Name
    let name = entry.name;
    if (entry.isDirectory) {
      name += '/';
    } else if (entry.isSymlink && entry.target) {
      name += ` -> ${entry.target}`;
    }
    parts.push(name);

    return parts.join('  ');
  }

  private formatHumanSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes}B`;
    } else if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)}K`;
    } else if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)}M`;
    } else {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)}G`;
    }
  }

  private formatDate(date: Date): string {
    const now = new Date();
    const year = date.getFullYear();
    const month = date.toLocaleString('en', { month: 'short' });
    const day = String(date.getDate()).padStart(2);

    if (year === now.getFullYear()) {
      const hours = String(date.getHours()).padStart(2, '0');
      const mins = String(date.getMinutes()).padStart(2, '0');
      return `${month} ${day} ${hours}:${mins}`;
    } else {
      return `${month} ${day}  ${year}`;
    }
  }
}
