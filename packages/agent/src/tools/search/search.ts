/**
 * @fileoverview Unified Search tool (text + AST search with auto-detection)
 *
 * Auto-detects whether to use text or AST search based on pattern syntax.
 * - Default: Text search (fast, works everywhere)
 * - AST mode: Pattern contains $VAR or $$$ metavariables, or type='ast' specified
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import { spawn } from 'child_process';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger, categorizeError } from '../../logging/index.js';
import { getSettings } from '../../settings/index.js';
import {
  truncateOutput,
  resolvePath,
  validateRequiredString,
  formatFsError,
} from '../utils.js';
// Simple glob matching helper (minimatch not in deps)
function matchesGlob(filename: string, pattern: string): boolean {
  const regex = pattern
    .replace(/\./g, '\\.')
    .replace(/\*/g, '.*')
    .replace(/\?/g, '.');
  return new RegExp(`^${regex}$`).test(filename);
}

const logger = createLogger('tool:search');

export interface SearchToolConfig {
  workingDirectory: string;
}

interface SearchMatch {
  file: string;
  line: number;
  content: string;
  column?: number;
}

/**
 * Detects if pattern contains AST metavariables
 */
function hasAstMetavariables(pattern: string): boolean {
  // Check for $VAR style metavariables or $$$ wildcards
  return /\$[A-Z_][A-Z0-9_]*|\$\$\$/.test(pattern);
}

export class SearchTool implements TronTool {
  readonly name = 'Search';
  readonly description = `Search code using text or AST patterns. Automatically detects search mode.

Text search (default):
- Fast regex-based content search
- Works for any text pattern

AST search (auto-detected):
- Structural code search using AST
- Triggered by $VAR or $$$ in pattern
- Example: "function $NAME() {}" finds all function definitions

Parameters:
- pattern: Search pattern (regex for text, AST pattern with $VAR for structural)
- path: File or directory to search (default: current directory)
- type: Force search mode ('text' or 'ast'), optional
- filePattern: Glob to filter files (e.g., "*.ts")
- context: Lines of context around matches (text mode only)

Examples:
- Text: { "pattern": "TODO.*bug" }
- AST: { "pattern": "function $NAME() {}" }
- Force: { "pattern": "test", "type": "ast" }`;

  readonly category = 'search' as const;
  readonly parameters = {
    type: 'object' as const,
    properties: {
      pattern: {
        type: 'string' as const,
        description: 'Search pattern (regex for text, AST pattern with $VAR for structural)',
      },
      path: {
        type: 'string' as const,
        description: 'File or directory to search (defaults to current directory)',
      },
      type: {
        type: 'string' as const,
        description: 'Force search mode: "text" or "ast"',
        enum: ['text', 'ast'],
      },
      filePattern: {
        type: 'string' as const,
        description: 'Glob pattern to filter files (e.g., "*.ts", "*.{js,jsx}")',
      },
      context: {
        type: 'number' as const,
        description: 'Number of context lines before/after match (text mode only)',
      },
      maxResults: {
        type: 'number' as const,
        description: 'Maximum number of results to return',
      },
    },
    required: ['pattern'] as string[],
  };

  private config: SearchToolConfig;
  private settings = getSettings();

  constructor(config: SearchToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate pattern
    const patternValidation = validateRequiredString(
      args,
      'pattern',
      'a search pattern',
      '"function.*test" or "$VAR" for AST'
    );
    if (!patternValidation.valid) return patternValidation.error!;

    const pattern = (args.pattern as string).trim();

    const searchPath = resolvePath(
      (args.path as string | undefined) || '.',
      this.config.workingDirectory
    );

    // Determine search mode
    const forceType = args.type as 'text' | 'ast' | undefined;
    const useAst = forceType === 'ast' || (forceType !== 'text' && hasAstMetavariables(pattern));
    const mode = useAst ? 'ast' : 'text';

    logger.info('Search', { pattern, searchPath, mode, forceType });

    try {
      if (mode === 'ast') {
        return await this.astSearch(pattern, searchPath, args);
      } else {
        return await this.textSearch(pattern, searchPath, args);
      }
    } catch (error) {
      const structured = categorizeError(error, { pattern, path: searchPath, mode });
      logger.error('Search failed', {
        pattern,
        path: searchPath,
        mode,
        error: structured.message,
      });
      return formatFsError(error, searchPath, 'searching');
    }
  }

  /**
   * Text-based regex search
   */
  private async textSearch(
    pattern: string,
    searchPath: string,
    args: Record<string, unknown>
  ): Promise<TronToolResult> {
    const filePattern = args.filePattern as string | undefined;
    // const context = (args.context as number | undefined) || 0; // TODO: Implement context support
    const maxResults = (args.maxResults as number | undefined) || this.settings.tools.grep.defaultMaxResults;

    const stat = await fs.stat(searchPath);
    const files: string[] = [];

    if (stat.isFile()) {
      files.push(searchPath);
    } else if (stat.isDirectory()) {
      await this.collectFiles(searchPath, files, filePattern, maxResults * 10);
    } else {
      return {
        content: `Not a file or directory: ${searchPath}`,
        isError: true,
      };
    }

    // Search files
    const regex = new RegExp(pattern, 'i');
    const matches: SearchMatch[] = [];

    for (const file of files) {
      if (matches.length >= maxResults) break;

      try {
        const content = await fs.readFile(file, 'utf-8');
        const lines = content.split('\n');

        for (let i = 0; i < lines.length; i++) {
          if (matches.length >= maxResults) break;

          const line = lines[i];
          if (line && regex.test(line)) {
            matches.push({
              file: path.relative(this.config.workingDirectory, file),
              line: i + 1,
              content: line.trim(),
            });
          }
        }
      } catch (err) {
        // Skip files that can't be read
        logger.debug('Skipping unreadable file', { file, error: String(err) });
      }
    }

    // Format output
    let output = '';
    if (matches.length === 0) {
      output = `No matches found for pattern: ${pattern}`;
    } else {
      output = matches
        .map(m => `${m.file}:${m.line}: ${m.content}`)
        .join('\n');

      if (matches.length >= maxResults) {
        output += `\n\n[Showing ${matches.length} results (limit reached)]`;
      }
    }

    // Truncate if needed
    const truncateResult = truncateOutput(output, this.settings.tools.grep.maxOutputTokens);

    return {
      content: truncateResult.content,
      isError: false,
      details: {
        mode: 'text',
        matches: matches.length,
        filesSearched: files.length,
        truncated: truncateResult.truncated,
      },
    };
  }

  /**
   * AST-based structural search using ast-grep
   */
  private async astSearch(
    pattern: string,
    searchPath: string,
    args: Record<string, unknown>
  ): Promise<TronToolResult> {
    const filePattern = args.filePattern as string | undefined;
    const maxResults = (args.maxResults as number | undefined) || this.settings.tools.astGrep.defaultLimit;

    return new Promise((resolve) => {
      const astGrepArgs: string[] = ['--json', '--pattern', pattern];

      if (filePattern) {
        astGrepArgs.push('--glob', filePattern);
      }

      astGrepArgs.push(searchPath);

      const astGrepSettings = this.settings.tools.astGrep;
      const binaryPath = astGrepSettings?.binaryPath || 'sg';
      const timeout = astGrepSettings?.defaultTimeoutMs || 60000;
      const maxOutputTokens = astGrepSettings?.maxOutputTokens || 15000;
      const proc = spawn(binaryPath, astGrepArgs, {
        cwd: this.config.workingDirectory,
        timeout,
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      proc.on('close', (code) => {
        if (code !== 0) {
          if (stderr.includes('not found') || stderr.includes('command not found')) {
            resolve({
              content: `ast-grep is not installed. Install it with: brew install ast-grep`,
              isError: true,
            });
            return;
          }

          resolve({
            content: `ast-grep failed: ${stderr}`,
            isError: true,
          });
          return;
        }

        try {
          const results = JSON.parse(stdout || '[]');
          const matches = results.slice(0, maxResults);

          let output = '';
          if (matches.length === 0) {
            output = `No matches found for AST pattern: ${pattern}`;
          } else {
            output = matches
              .map((m: any) => `${m.file}:${m.line}: ${m.code || m.text || ''}`)
              .join('\n');

            if (results.length > maxResults) {
              output += `\n\n[Showing ${maxResults} of ${results.length} results]`;
            }
          }

          const truncateResult = truncateOutput(output, maxOutputTokens);

          resolve({
            content: truncateResult.content,
            isError: false,
            details: {
              mode: 'ast',
              matches: matches.length,
              totalMatches: results.length,
              truncated: truncateResult.truncated,
            },
          });
        } catch (err) {
          resolve({
            content: `Failed to parse ast-grep output: ${String(err)}`,
            isError: true,
          });
        }
      });

      proc.on('error', (err) => {
        resolve({
          content: `Failed to spawn ast-grep: ${err.message}`,
          isError: true,
        });
      });
    });
  }

  /**
   * Recursively collect files matching optional glob pattern
   */
  private async collectFiles(
    dir: string,
    files: string[],
    filePattern: string | undefined,
    maxFiles: number
  ): Promise<void> {
    if (files.length >= maxFiles) return;

    const skipDirs = ['node_modules', '.git', 'dist', 'build', '.next', 'coverage'];
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      if (files.length >= maxFiles) break;

      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory()) {
        // Skip common ignore directories
        if (skipDirs.includes(entry.name) || entry.name.startsWith('.')) {
          continue;
        }
        await this.collectFiles(fullPath, files, filePattern, maxFiles);
      } else if (entry.isFile()) {
        // Apply glob filter if provided
        if (filePattern && !matchesGlob(entry.name, filePattern)) {
          continue;
        }
        files.push(fullPath);
      }
    }
  }
}
