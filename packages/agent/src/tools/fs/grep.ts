/**
 * @fileoverview Grep tool for content search
 *
 * Searches file contents using regex patterns with support for
 * recursive directory search and glob filtering.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger, categorizeError } from '../../logging/index.js';
import { getSettings } from '../../settings/index.js';
import type { GrepToolSettings } from '../../settings/types.js';
import {
  truncateOutput,
  resolvePath,
  validateRequiredString,
  validateNonEmptyString,
  formatFsError,
} from '../utils.js';

const logger = createLogger('tool:grep');

/**
 * Get default grep settings from the global settings.
 * Used for backwards compatibility when settings not explicitly provided.
 */
export function getDefaultGrepSettings(): GrepToolSettings {
  return getSettings().tools.grep;
}

export interface GrepToolConfig {
  workingDirectory: string;
  /** Grep tool settings. If not provided, uses global settings. */
  grepSettings?: GrepToolSettings;
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
  private grepSettings: GrepToolSettings;
  private binaryExtensionsSet: Set<string> | null = null;
  private skipDirectoriesSet: Set<string> | null = null;

  constructor(config: GrepToolConfig) {
    this.config = config;
    this.grepSettings = config.grepSettings ?? getDefaultGrepSettings();
  }

  /**
   * Get binary extensions set (cached per instance).
   */
  private getBinaryExtensions(): Set<string> {
    if (!this.binaryExtensionsSet) {
      this.binaryExtensionsSet = new Set(this.grepSettings.binaryExtensions);
    }
    return this.binaryExtensionsSet;
  }

  /**
   * Get skip directories set (cached per instance).
   */
  private getSkipDirectories(): Set<string> {
    if (!this.skipDirectoriesSet) {
      this.skipDirectoriesSet = new Set(this.grepSettings.skipDirectories);
    }
    return this.skipDirectoriesSet;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate required parameters
    const patternValidation = validateRequiredString(
      args, 'pattern', 'a regex pattern to search for',
      '"function.*export" or "TODO"'
    );
    if (!patternValidation.valid) return patternValidation.error!;

    const patternStr = (args.pattern as string).trim();
    const emptyValidation = validateNonEmptyString(patternStr, 'pattern', '"function.*" or "TODO"');
    if (!emptyValidation.valid) return emptyValidation.error!;

    const searchPath = resolvePath((args.path as string) || '.', this.config.workingDirectory);
    const globPattern = args.glob as string | undefined;
    const ignoreCase = (args.ignoreCase as boolean) ?? false;
    const contextLines = (args.context as number) ?? 0;
    const maxResults = (args.maxResults as number) ?? this.grepSettings.defaultMaxResults;

    const startTime = Date.now();
    logger.debug('Grep search', { pattern: patternStr, searchPath, globPattern, ignoreCase });

    try {
      const regex = new RegExp(patternStr, ignoreCase ? 'gi' : 'g');
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
          content: `No matches found for pattern: ${patternStr}`,
          isError: false,
          details: { pattern: patternStr, searchPath, matchCount: 0 },
        };
      }

      const output = this.formatMatches(matches, contextLines > 0);

      // Apply token-based truncation
      const maxOutputTokens = this.grepSettings.maxOutputTokens ?? 15000;
      const truncateResult = truncateOutput(output, maxOutputTokens, {
        preserveStartLines: 5,
        truncationMessage: `\n\n... [Results truncated: ${matches.length} matches found. Output exceeded ${maxOutputTokens.toLocaleString()} token limit. Use maxResults parameter or narrow your search.]`,
      });

      const resultsTruncated = truncated || truncateResult.truncated;

      const duration = Date.now() - startTime;
      logger.info('Grep search completed', {
        pattern: patternStr,
        searchPath,
        matchCount: matches.length,
        truncated: resultsTruncated,
        duration,
      });

      return {
        content: truncateResult.content,
        isError: false,
        details: {
          pattern: patternStr,
          searchPath,
          matchCount: matches.length,
          truncated: resultsTruncated,
          ...(truncateResult.truncated && {
            originalTokens: truncateResult.originalTokens,
            finalTokens: truncateResult.finalTokens,
          }),
        },
      };
    } catch (error) {
      const duration = Date.now() - startTime;
      const structuredError = categorizeError(error, { searchPath, pattern: patternStr, operation: 'grep' });
      logger.error('Grep search failed', {
        searchPath,
        pattern: patternStr,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        duration,
      });
      return formatFsError(error, searchPath, 'searching');
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
      const stat = await fs.stat(filePath);
      if (stat.size > this.grepSettings.maxFileSizeBytes) {
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
        const skipDirs = this.getSkipDirectories();
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
    return this.getBinaryExtensions().has(ext);
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
}
