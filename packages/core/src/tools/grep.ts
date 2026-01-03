/**
 * @fileoverview Grep tool for content search
 *
 * Searches file contents using regex patterns with support for
 * recursive directory search and glob filtering.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('tool:grep');

// Get grep tool settings (loaded lazily on first access)
function getGrepSettings() {
  return getSettings().tools.grep;
}

// Cache binary extensions set (built from settings on first access)
let binaryExtensionsSet: Set<string> | null = null;
function getBinaryExtensions(): Set<string> {
  if (!binaryExtensionsSet) {
    binaryExtensionsSet = new Set(getGrepSettings().binaryExtensions);
  }
  return binaryExtensionsSet;
}

// Cache skip directories set (built from settings on first access)
let skipDirectoriesSet: Set<string> | null = null;
function getSkipDirectories(): Set<string> {
  if (!skipDirectoriesSet) {
    skipDirectoriesSet = new Set(getGrepSettings().skipDirectories);
  }
  return skipDirectoriesSet;
}

export interface GrepToolConfig {
  workingDirectory: string;
}

interface GrepMatch {
  file: string;
  line: number;
  content: string;
}

export class GrepTool implements TronTool {
  readonly name = 'Grep';
  readonly description = 'Search file contents for a pattern. Returns matching lines with file paths and line numbers.';
  readonly category = 'search' as const;
  readonly parameters = {
    type: 'object' as const,
    properties: {
      pattern: {
        type: 'string' as const,
        description: 'Regex pattern to search for',
      },
      path: {
        type: 'string' as const,
        description: 'File or directory to search (defaults to current directory)',
      },
      glob: {
        type: 'string' as const,
        description: 'Glob pattern to filter files (e.g., "*.ts", "*.{js,jsx}")',
      },
      ignoreCase: {
        type: 'boolean' as const,
        description: 'Case insensitive search',
      },
      context: {
        type: 'number' as const,
        description: 'Number of context lines before/after match',
      },
      maxResults: {
        type: 'number' as const,
        description: 'Maximum number of results to return',
      },
    },
    required: ['pattern'] as string[],
  };

  private config: GrepToolConfig;

  constructor(config: GrepToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    const settings = getGrepSettings();
    const pattern = args.pattern as string;
    const searchPath = this.resolvePath((args.path as string) || '.');
    const globPattern = args.glob as string | undefined;
    const ignoreCase = (args.ignoreCase as boolean) ?? false;
    const contextLines = (args.context as number) ?? 0;
    const maxResults = (args.maxResults as number) ?? settings.defaultMaxResults;

    logger.debug('Grep search', { pattern, searchPath, globPattern, ignoreCase });

    try {
      const regex = new RegExp(pattern, ignoreCase ? 'gi' : 'g');
      const matches: GrepMatch[] = [];
      let truncated = false;

      const stat = await fs.stat(searchPath);

      if (stat.isFile()) {
        await this.searchFile(searchPath, regex, matches, maxResults, contextLines);
      } else if (stat.isDirectory()) {
        await this.searchDirectory(searchPath, regex, matches, maxResults, globPattern, contextLines);
      }

      truncated = matches.length >= maxResults;

      if (matches.length === 0) {
        return {
          content: `No matches found for pattern: ${pattern}`,
          isError: false,
          details: { pattern, searchPath, matchCount: 0 },
        };
      }

      const output = this.formatMatches(matches, contextLines > 0);

      logger.debug('Grep completed', { matchCount: matches.length, truncated });

      return {
        content: output,
        isError: false,
        details: {
          pattern,
          searchPath,
          matchCount: matches.length,
          truncated,
        },
      };
    } catch (error) {
      const err = error as NodeJS.ErrnoException;
      logger.error('Grep failed', { searchPath, error: err.message });

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

  private async searchFile(
    filePath: string,
    regex: RegExp,
    matches: GrepMatch[],
    maxResults: number,
    contextLines: number
  ): Promise<void> {
    if (this.isBinaryFile(filePath)) {
      return;
    }

    try {
      const settings = getGrepSettings();
      const stat = await fs.stat(filePath);
      if (stat.size > settings.maxFileSizeBytes) {
        logger.debug('Skipping large file', { filePath, size: stat.size });
        return;
      }

      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n');

      for (let i = 0; i < lines.length && matches.length < maxResults; i++) {
        const currentLine = lines[i] ?? '';
        // Reset regex lastIndex for each line
        regex.lastIndex = 0;
        if (regex.test(currentLine)) {
          if (contextLines > 0) {
            // Add context lines
            const startLine = Math.max(0, i - contextLines);
            const endLine = Math.min(lines.length - 1, i + contextLines);
            for (let j = startLine; j <= endLine && matches.length < maxResults; j++) {
              matches.push({
                file: filePath,
                line: j + 1,
                content: lines[j] ?? '',
              });
            }
          } else {
            matches.push({
              file: filePath,
              line: i + 1,
              content: currentLine,
            });
          }
        }
      }
    } catch (error) {
      // Skip files that can't be read (binary, permissions, etc.)
      logger.debug('Skipping file', { filePath, error: (error as Error).message });
    }
  }

  private async searchDirectory(
    dirPath: string,
    regex: RegExp,
    matches: GrepMatch[],
    maxResults: number,
    globPattern: string | undefined,
    contextLines: number
  ): Promise<void> {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });

    for (const entry of entries) {
      if (matches.length >= maxResults) {
        break;
      }

      const fullPath = path.join(dirPath, entry.name);

      // Skip hidden directories and common non-code directories
      if (entry.isDirectory()) {
        const skipDirs = getSkipDirectories();
        if (entry.name.startsWith('.') || skipDirs.has(entry.name)) {
          continue;
        }
        await this.searchDirectory(fullPath, regex, matches, maxResults, globPattern, contextLines);
      } else if (entry.isFile()) {
        if (globPattern && !this.matchGlob(entry.name, globPattern)) {
          continue;
        }
        await this.searchFile(fullPath, regex, matches, maxResults, contextLines);
      }
    }
  }

  private matchGlob(filename: string, pattern: string): boolean {
    // Simple glob matching (*.ts, *.{js,ts}, etc.)
    const regexPattern = pattern
      .replace(/\./g, '\\.')
      .replace(/\*/g, '.*')
      .replace(/\{([^}]+)\}/g, (_, group) => `(${group.split(',').join('|')})`);
    return new RegExp(`^${regexPattern}$`).test(filename);
  }

  private isBinaryFile(filePath: string): boolean {
    const ext = path.extname(filePath).toLowerCase();
    return getBinaryExtensions().has(ext);
  }

  private formatMatches(matches: GrepMatch[], hasContext: boolean): string {
    const lines: string[] = [];
    let currentFile = '';

    for (const match of matches) {
      if (match.file !== currentFile) {
        if (lines.length > 0) {
          lines.push('');
        }
        lines.push(`${match.file}:`);
        currentFile = match.file;
      }
      const prefix = hasContext ? `  ${match.line}:` : `${match.line}:`;
      lines.push(`${prefix} ${match.content}`);
    }

    return lines.join('\n');
  }

  private resolvePath(filePath: string): string {
    if (path.isAbsolute(filePath)) {
      return filePath;
    }
    return path.join(this.config.workingDirectory, filePath);
  }
}
