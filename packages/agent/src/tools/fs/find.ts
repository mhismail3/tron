/**
 * @fileoverview Find tool for file search
 *
 * Searches for files matching glob patterns with support for
 * type filtering, depth limits, and exclusions.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger } from '../../logging/logger.js';
import { getSettings } from '../../settings/index.js';

const logger = createLogger('tool:find');

// Get find tool settings (loaded lazily on first access)
function getFindSettings() {
  return getSettings().tools.find;
}

export interface FindToolConfig {
  workingDirectory: string;
}

interface FileEntry {
  path: string;
  name: string;
  isDirectory: boolean;
  size?: number;
  mtime?: Date;
}

export class FindTool implements TronTool {
  readonly name = 'Find';
  readonly description = 'Search for files matching a glob pattern. Returns file paths relative to search directory.';
  readonly category = 'search' as const;
  readonly parameters = {
    type: 'object' as const,
    properties: {
      pattern: {
        type: 'string' as const,
        description: 'Glob pattern to match files (e.g., "*.ts", "**/*.js", "src/**/*.tsx")',
      },
      path: {
        type: 'string' as const,
        description: 'Directory to search in (defaults to current directory)',
      },
      type: {
        type: 'string' as const,
        description: 'Filter by type: "file", "directory", or "all"',
        enum: ['file', 'directory', 'all'],
      },
      maxDepth: {
        type: 'number' as const,
        description: 'Maximum directory depth to search',
      },
      exclude: {
        type: 'array' as const,
        description: 'Patterns to exclude from results',
        items: { type: 'string' as const },
      },
      showSize: {
        type: 'boolean' as const,
        description: 'Show file sizes in results',
      },
      sortByTime: {
        type: 'boolean' as const,
        description: 'Sort results by modification time (newest first)',
      },
      maxResults: {
        type: 'number' as const,
        description: 'Maximum number of results to return',
      },
    },
    required: ['pattern'] as string[],
  };

  private config: FindToolConfig;

  constructor(config: FindToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate required parameters (defense against truncated tool calls)
    if (!args.pattern || typeof args.pattern !== 'string') {
      return {
        content: 'Missing required parameter: pattern. Please provide a glob pattern to match files. Example: "*.ts", "**/*.js", or "src/**/*.tsx"',
        isError: true,
        details: { pattern: args.pattern },
      };
    }

    const patternStr = args.pattern.trim();
    if (patternStr === '') {
      return {
        content: 'Invalid pattern: pattern cannot be empty. Please provide a glob pattern like "*.ts" or "**/*.js"',
        isError: true,
        details: { pattern: args.pattern },
      };
    }

    const settings = getFindSettings();
    const searchPath = this.resolvePath((args.path as string) || '.');
    const typeFilter = (args.type as 'file' | 'directory' | 'all') ?? 'all';
    const maxDepth = (args.maxDepth as number) ?? settings.defaultMaxDepth;
    const excludePatterns = (args.exclude as string[]) ?? [];
    const showSize = (args.showSize as boolean) ?? false;
    const sortByTime = (args.sortByTime as boolean) ?? false;
    const maxResults = (args.maxResults as number) ?? settings.defaultMaxResults;

    logger.debug('Find search', { pattern: patternStr, searchPath, typeFilter, maxDepth });

    try {
      const stat = await fs.stat(searchPath);

      if (!stat.isDirectory()) {
        return {
          content: `Path is not a directory: ${searchPath}`,
          isError: true,
          details: { searchPath },
        };
      }

      const entries: FileEntry[] = [];
      const globRegex = this.patternToRegex(patternStr);

      await this.searchDirectory(
        searchPath,
        searchPath,
        globRegex,
        entries,
        maxResults,
        maxDepth,
        0,
        typeFilter,
        excludePatterns,
        showSize || sortByTime
      );

      if (entries.length === 0) {
        return {
          content: `No files found matching: ${patternStr}`,
          isError: false,
          details: { pattern: patternStr, searchPath, fileCount: 0 },
        };
      }

      // Sort if needed
      if (sortByTime) {
        entries.sort((a, b) => {
          const timeA = a.mtime?.getTime() ?? 0;
          const timeB = b.mtime?.getTime() ?? 0;
          return timeB - timeA; // Newest first
        });
      }

      const truncated = entries.length >= maxResults;
      const output = this.formatEntries(entries, searchPath, showSize);

      logger.debug('Find completed', { fileCount: entries.length, truncated });

      return {
        content: output,
        isError: false,
        details: {
          pattern: patternStr,
          searchPath,
          fileCount: entries.length,
          truncated,
        },
      };
    } catch (error) {
      const err = error as NodeJS.ErrnoException;
      logger.error('Find failed', { searchPath, error: err.message });

      if (err.code === 'ENOENT') {
        return {
          content: `Path not found: ${searchPath}`,
          isError: true,
          details: { searchPath, errorCode: err.code },
        };
      }

      return {
        content: `Search failed: ${err.message}`,
        isError: true,
        details: { searchPath, error: err.message },
      };
    }
  }

  private async searchDirectory(
    basePath: string,
    currentPath: string,
    pattern: RegExp,
    entries: FileEntry[],
    maxResults: number,
    maxDepth: number,
    currentDepth: number,
    typeFilter: 'file' | 'directory' | 'all',
    excludePatterns: string[],
    needStats: boolean
  ): Promise<void> {
    if (currentDepth > maxDepth || entries.length >= maxResults) {
      return;
    }

    try {
      const dirEntries = await fs.readdir(currentPath, { withFileTypes: true });

      for (const entry of dirEntries) {
        if (entries.length >= maxResults) {
          break;
        }

        const fullPath = path.join(currentPath, entry.name);
        const relativePath = path.relative(basePath, fullPath);

        // Check exclusions
        if (this.isExcluded(entry.name, excludePatterns)) {
          continue;
        }

        // Skip hidden directories for recursive search
        if (entry.isDirectory() && entry.name.startsWith('.')) {
          continue;
        }

        const matchesPattern = pattern.test(relativePath) || pattern.test(entry.name);

        if (matchesPattern) {
          const matchesType =
            typeFilter === 'all' ||
            (typeFilter === 'file' && entry.isFile()) ||
            (typeFilter === 'directory' && entry.isDirectory());

          if (matchesType) {
            const fileEntry: FileEntry = {
              path: relativePath,
              name: entry.name,
              isDirectory: entry.isDirectory(),
            };

            if (needStats && entry.isFile()) {
              try {
                const stat = await fs.stat(fullPath);
                fileEntry.size = stat.size;
                fileEntry.mtime = stat.mtime;
              } catch {
                // Ignore stat errors
              }
            }

            entries.push(fileEntry);
          }
        }

        // Recurse into directories
        if (entry.isDirectory()) {
          await this.searchDirectory(
            basePath,
            fullPath,
            pattern,
            entries,
            maxResults,
            maxDepth,
            currentDepth + 1,
            typeFilter,
            excludePatterns,
            needStats
          );
        }
      }
    } catch (error) {
      // Skip directories we can't read
      logger.debug('Skipping directory', { currentPath, error: (error as Error).message });
    }
  }

  private patternToRegex(pattern: string): RegExp {
    // Handle ** for recursive matching
    // IMPORTANT: Escape special regex chars BEFORE converting glob patterns
    let regexPattern = pattern
      .replace(/\./g, '\\.')                    // Escape dots first
      .replace(/\?/g, '.')                      // ? matches single char
      .replace(/\{([^}]+)\}/g, (_, group) => `(${group.split(',').join('|')})`)
      .replace(/\*\*\//g, '(.*\\/)?')           // **/ matches zero or more path segments
      .replace(/\*\*/g, '.*')                   // ** at end matches anything
      .replace(/\*/g, '[^/]*');                 // * matches anything except /

    return new RegExp(`^${regexPattern}$`);
  }

  private isExcluded(name: string, patterns: string[]): boolean {
    for (const pattern of patterns) {
      if (name === pattern || this.matchSimpleGlob(name, pattern)) {
        return true;
      }
    }
    return false;
  }

  private matchSimpleGlob(name: string, pattern: string): boolean {
    const regexPattern = pattern
      .replace(/\./g, '\\.')
      .replace(/\*/g, '.*')
      .replace(/\?/g, '.');
    return new RegExp(`^${regexPattern}$`).test(name);
  }

  private formatEntries(entries: FileEntry[], _basePath: string, showSize: boolean): string {
    const lines: string[] = [];

    for (const entry of entries) {
      let line = entry.path;

      if (entry.isDirectory) {
        line += '/';
      }

      if (showSize && entry.size !== undefined) {
        const sizeStr = this.formatSize(entry.size);
        line = `${sizeStr.padStart(8)}  ${line}`;
      }

      lines.push(line);
    }

    return lines.join('\n');
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes}`;
    } else if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)}K`;
    } else if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)}M`;
    } else {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)}G`;
    }
  }

  private resolvePath(filePath: string): string {
    if (path.isAbsolute(filePath)) {
      return filePath;
    }
    return path.join(this.config.workingDirectory, filePath);
  }
}
