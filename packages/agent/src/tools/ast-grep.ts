/**
 * @fileoverview AstGrep tool for structural code search
 *
 * Provides AST-based code search and refactoring capabilities using ast-grep.
 * Supports search, replace, count, and inspect modes.
 */

import { spawn } from 'child_process';
import * as path from 'path';
import * as fs from 'fs/promises';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';
import { truncateOutput } from './utils.js';

const logger = createLogger('tool:ast-grep');

// Get ast-grep tool settings (loaded lazily on first access)
function getAstGrepSettings() {
  const settings = getSettings();
  return (settings.tools as any).astGrep ?? {
    defaultLimit: 50,
    maxLimit: 200,
    defaultContext: 0,
    maxOutputTokens: 15000,
    defaultTimeoutMs: 60000,
    skipDirectories: ['node_modules', '.git', 'dist', 'build', 'vendor'],
  };
}

// Install instructions for all platforms
const INSTALL_INSTRUCTIONS = `ast-grep is not installed. Install with one of:

macOS:
  brew install ast-grep

npm (all platforms):
  npm install -g @ast-grep/cli

cargo (all platforms):
  cargo install ast-grep --locked

Windows (scoop):
  scoop install ast-grep

Then retry this command.`;

// Valid modes
const VALID_MODES = ['search', 'replace', 'count', 'inspect'] as const;
type Mode = typeof VALID_MODES[number];

// Supported languages
const SUPPORTED_LANGUAGES = [
  'js', 'javascript', 'ts', 'typescript', 'tsx', 'jsx',
  'py', 'python', 'go', 'rust', 'java', 'c', 'cpp', 'c++',
  'csharp', 'cs', 'kotlin', 'swift', 'ruby', 'php',
  'html', 'css', 'json', 'yaml', 'toml',
];

export interface AstGrepToolConfig {
  workingDirectory: string;
}

export interface AstGrepMatch {
  file: string;
  line: number;
  column: number;
  code: string;
  captured: Record<string, string>;
}

export interface AstGrepDetails {
  matches?: AstGrepMatch[];
  totalMatches?: number;
  filesSearched?: number;
  filesModified?: number;
  replacements?: number;
  count?: number;
  filesWithMatches?: number;
  truncated?: boolean;
  truncatedFrom?: number;
}

export class AstGrepTool implements TronTool {
  readonly name = 'AstGrep';
  readonly category = 'search' as const;
  readonly description = `Structural code search using AST patterns.

Unlike text-based grep, this tool understands code structure:
- Pattern "console.log($MSG)" matches any console.log call
- Pattern "$A == $A" finds equality checks with identical operands
- Metavariables: $VAR (single node), $$$ (multiple nodes), $_ (anonymous)

Modes:
- search: Find patterns, return structured matches (default)
- replace: Find and replace with --rewrite
- count: Quick count of matches
- inspect: Debug pattern parsing

Examples:
- Find all console.log: pattern="console.log($$$)"
- Find var declarations: pattern="var $NAME = $VALUE" lang="js"
- Replace var→let: pattern="var $N = $V" replacement="let $N = $V" mode="replace"`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      pattern: {
        type: 'string' as const,
        description: 'AST pattern to match. Use $VAR for single node, $$$ for multiple nodes.',
      },
      mode: {
        type: 'string' as const,
        enum: VALID_MODES as unknown as string[],
        description: 'Operation mode: search (default), replace, count, or inspect',
      },
      replacement: {
        type: 'string' as const,
        description: 'Replacement pattern for replace mode. Use same metavariables from pattern.',
      },
      path: {
        type: 'string' as const,
        description: 'File or directory to search (defaults to working directory)',
      },
      lang: {
        type: 'string' as const,
        description: 'Language (js, ts, tsx, py, go, rust, java, etc.). Auto-detected from files.',
      },
      globs: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'File patterns to include (e.g., ["**/*.ts", "!**/*.test.ts"])',
      },
      context: {
        type: 'number' as const,
        description: 'Lines of context around matches (default: 0)',
      },
      limit: {
        type: 'number' as const,
        description: 'Maximum results to return (default: 50)',
      },
    },
    required: ['pattern'] as string[],
  };

  private config: AstGrepToolConfig;
  private binaryPath: string | null = null;
  private binaryChecked = false;

  constructor(config: AstGrepToolConfig) {
    this.config = config;
  }

  /**
   * Find ast-grep binary, trying 'sg' first then 'ast-grep'
   */
  private async findBinaryPath(): Promise<string | null> {
    const binaries = ['sg', 'ast-grep'];

    for (const binary of binaries) {
      try {
        const result = await this.runCommand(binary, ['--version'], 5000);
        if (result.exitCode === 0) {
          logger.debug('Found ast-grep binary', { binary, version: result.stdout.trim() });
          return binary;
        }
      } catch {
        continue;
      }
    }

    return null;
  }

  /**
   * Get cached binary path, checking installation on first call
   */
  private async getBinaryPath(): Promise<string> {
    if (!this.binaryChecked) {
      this.binaryPath = await this.findBinaryPath();
      this.binaryChecked = true;
    }

    if (!this.binaryPath) {
      throw new Error('ast-grep not installed');
    }

    return this.binaryPath;
  }

  /**
   * Run a command with spawn (no shell interpretation for security)
   */
  private runCommand(
    binary: string,
    args: string[],
    timeout: number,
    cwd?: string,
    signal?: AbortSignal
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    return new Promise((resolve, reject) => {
      const proc = spawn(binary, args, {
        cwd: cwd ?? this.config.workingDirectory,
        shell: false,
        timeout,
        signal,
      });

      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', (data) => { stdout += data; });
      proc.stderr.on('data', (data) => { stderr += data; });

      proc.on('close', (code) => {
        resolve({ stdout, stderr, exitCode: code ?? 0 });
      });

      proc.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'ETIMEDOUT' || err.message.includes('timeout')) {
          reject(new Error(`Timeout after ${timeout}ms`));
        } else if (err.code === 'ABORT_ERR') {
          reject(new Error('Operation cancelled'));
        } else {
          reject(err);
        }
      });
    });
  }

  /**
   * Validate input parameters
   */
  private validateParams(args: Record<string, unknown>): { valid: boolean; error?: string } {
    // Required: pattern
    if (!args.pattern || typeof args.pattern !== 'string') {
      return { valid: false, error: 'Missing required parameter: pattern. Please provide an AST pattern to search for.' };
    }

    const pattern = (args.pattern as string).trim();
    if (pattern === '') {
      return { valid: false, error: 'Invalid pattern: pattern cannot be empty.' };
    }

    // Mode validation
    const mode = args.mode as string | undefined;
    if (mode && !VALID_MODES.includes(mode as Mode)) {
      return { valid: false, error: `Invalid mode: ${mode}. Must be one of: ${VALID_MODES.join(', ')}` };
    }

    // Replace mode requires replacement
    if (mode === 'replace' && !args.replacement) {
      return { valid: false, error: 'Replace mode requires a replacement parameter.' };
    }

    // Language validation
    const lang = args.lang as string | undefined;
    if (lang && !SUPPORTED_LANGUAGES.includes(lang.toLowerCase())) {
      return { valid: false, error: `Invalid language: ${lang}. Supported: ${SUPPORTED_LANGUAGES.slice(0, 10).join(', ')}...` };
    }

    // Limit bounds
    if (args.limit !== undefined) {
      const limit = Number(args.limit);
      if (isNaN(limit) || limit < 1) {
        return { valid: false, error: 'Invalid limit: must be a positive number.' };
      }
      if (limit > 1000) {
        return { valid: false, error: 'Invalid limit: must be <= 1000.' };
      }
    }

    // Context validation
    if (args.context !== undefined) {
      const context = Number(args.context);
      if (isNaN(context) || context < 0) {
        return { valid: false, error: 'Invalid context: must be a non-negative number.' };
      }
    }

    // Path security check
    if (args.path) {
      const requestedPath = args.path as string;
      const normalizedPath = path.resolve(this.config.workingDirectory, requestedPath);
      if (!normalizedPath.startsWith(this.config.workingDirectory) && !requestedPath.startsWith('/')) {
        // Allow absolute paths but check for traversal in relative paths
        if (requestedPath.includes('..')) {
          return { valid: false, error: 'Invalid path: path traversal not allowed.' };
        }
      }
    }

    return { valid: true };
  }

  /**
   * Resolve path relative to working directory
   */
  private resolvePath(filePath: string): string {
    if (path.isAbsolute(filePath)) {
      return filePath;
    }
    return path.join(this.config.workingDirectory, filePath);
  }

  /**
   * Build command arguments based on mode and parameters
   */
  private buildArgs(args: Record<string, unknown>): string[] {
    const pattern = args.pattern as string;
    const mode = (args.mode as Mode) ?? 'search';
    const searchPath = args.path ? this.resolvePath(args.path as string) : this.config.workingDirectory;

    const cmdArgs: string[] = [];

    if (mode === 'inspect') {
      // Inspect mode: show AST for pattern
      cmdArgs.push('--debug-query');
      cmdArgs.push('--pattern', pattern);
      if (args.lang) {
        cmdArgs.push('--lang', args.lang as string);
      }
      return cmdArgs;
    }

    // Base command for search/replace/count
    cmdArgs.push('run');
    cmdArgs.push('--pattern', pattern);

    // Language
    if (args.lang) {
      cmdArgs.push('--lang', args.lang as string);
    }

    // Replacement for replace mode
    if (mode === 'replace' && args.replacement) {
      cmdArgs.push('--rewrite', args.replacement as string);
      cmdArgs.push('--update-all'); // Apply all changes without prompting
    }

    // Globs
    if (args.globs && Array.isArray(args.globs)) {
      for (const glob of args.globs) {
        cmdArgs.push('--globs', glob);
      }
    }

    // Context lines
    if (args.context && Number(args.context) > 0) {
      cmdArgs.push('-C', String(args.context));
    }

    // Don't respect gitignore - we want to search all code files
    cmdArgs.push('--no-ignore', 'vcs');

    // JSON output for parsing (except replace mode)
    if (mode !== 'replace') {
      cmdArgs.push('--json=stream');
    }

    // Path
    cmdArgs.push(searchPath);

    return cmdArgs;
  }

  /**
   * Parse JSON stream output from ast-grep
   */
  private parseJsonOutput(stdout: string): AstGrepMatch[] {
    const matches: AstGrepMatch[] = [];

    // ast-grep --json=stream outputs one JSON object per line
    const lines = stdout.trim().split('\n').filter(line => line.trim());

    for (const line of lines) {
      try {
        const obj = JSON.parse(line);
        if (obj.file && obj.range) {
          // Extract captured metavariables
          // Format: metaVariables: { single: { VAR: { text: "..." } }, multi: { VAR: [...] } }
          const captured: Record<string, string> = {};
          if (obj.metaVariables) {
            // Handle single metavariables
            if (obj.metaVariables.single) {
              for (const [key, value] of Object.entries(obj.metaVariables.single)) {
                captured[key] = (value as any).text || '';
              }
            }
            // Handle multi metavariables ($$$ patterns)
            if (obj.metaVariables.multi) {
              for (const [key, values] of Object.entries(obj.metaVariables.multi)) {
                if (Array.isArray(values)) {
                  captured[key] = values.map((v: any) => v.text || '').join(', ');
                }
              }
            }
          }

          matches.push({
            file: obj.file,
            line: obj.range.start.line + 1, // Convert 0-indexed to 1-indexed
            column: obj.range.start.column,
            code: obj.text || '',
            captured,
          });
        }
      } catch {
        // Skip malformed JSON lines
        logger.debug('Skipping malformed JSON line', { line });
      }
    }

    return matches;
  }

  /**
   * Format matches for human-readable output
   */
  private formatMatches(matches: AstGrepMatch[], context: number): string {
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

      const prefix = context > 0 ? `  ${match.line}:${match.column}:` : `${match.line}:`;
      lines.push(`${prefix} ${match.code}`);

      // Show captured variables if present
      if (Object.keys(match.captured).length > 0) {
        const capturedStr = Object.entries(match.captured)
          .map(([k, v]) => `${k}="${v}"`)
          .join(', ');
        lines.push(`    captured: ${capturedStr}`);
      }
    }

    return lines.join('\n');
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult<AstGrepDetails>> {
    // Validate parameters
    const validation = this.validateParams(args);
    if (!validation.valid) {
      return {
        content: validation.error!,
        isError: true,
        details: { pattern: args.pattern } as AstGrepDetails,
      };
    }

    // Check if ast-grep is installed
    let binary: string;
    try {
      binary = await this.getBinaryPath();
    } catch {
      return {
        content: INSTALL_INSTRUCTIONS,
        isError: true,
        details: {},
      };
    }

    const pattern = (args.pattern as string).trim();
    const mode = (args.mode as Mode) ?? 'search';
    const settings = getAstGrepSettings();
    const limit = Math.min(
      (args.limit as number) ?? settings.defaultLimit,
      settings.maxLimit
    );
    const context = (args.context as number) ?? settings.defaultContext;
    const timeout = settings.defaultTimeoutMs ?? 60000;
    const searchPath = args.path ? this.resolvePath(args.path as string) : this.config.workingDirectory;

    logger.debug('AstGrep execute', { pattern, mode, searchPath, limit });

    // Check path exists
    try {
      await fs.access(searchPath);
    } catch {
      return {
        content: `Path not found: ${searchPath}`,
        isError: true,
        details: {},
      };
    }

    try {
      const cmdArgs = this.buildArgs(args);

      logger.debug('Running ast-grep', { binary, args: cmdArgs });

      const result = await this.runCommand(binary, cmdArgs, timeout, this.config.workingDirectory);

      // Handle different modes
      if (mode === 'inspect') {
        return {
          content: result.stdout || result.stderr || 'No AST output',
          isError: result.exitCode !== 0,
          details: {},
        };
      }

      if (mode === 'replace') {
        // Parse replace output to count changes
        const output = result.stdout + result.stderr;
        const filesModified = (output.match(/Updated \d+ file/g) || []).length ||
                             (output.match(/modified/gi) || []).length;
        const replacements = (output.match(/\d+ replacement/g) || []).length;

        return {
          content: output || 'Replace completed',
          isError: result.exitCode !== 0,
          details: {
            filesModified: filesModified || (result.exitCode === 0 ? 1 : 0),
            replacements: replacements || (result.exitCode === 0 ? 1 : 0),
          },
        };
      }

      // Search or count mode
      const matches = this.parseJsonOutput(result.stdout);
      const totalMatches = matches.length;

      if (mode === 'count') {
        // Count unique files
        const filesWithMatches = new Set(matches.map(m => m.file)).size;

        return {
          content: `Found ${totalMatches} matches in ${filesWithMatches} files`,
          isError: false,
          details: {
            count: totalMatches,
            filesWithMatches,
          },
        };
      }

      // Search mode - apply limit and format
      const limitedMatches = matches.slice(0, limit);
      const truncatedByLimit = matches.length > limit;

      if (limitedMatches.length === 0) {
        return {
          content: `No matches found for pattern: ${pattern}`,
          isError: false,
          details: {
            matches: [],
            totalMatches: 0,
            truncated: false,
          },
        };
      }

      // Format output
      const output = this.formatMatches(limitedMatches, context);

      // Apply token-based truncation
      const maxOutputTokens = settings.maxOutputTokens ?? 15000;
      const truncateResult = truncateOutput(output, maxOutputTokens, {
        preserveStartLines: 5,
        truncationMessage: `\n\n... [Results truncated: ${totalMatches} matches found. Output exceeded ${maxOutputTokens.toLocaleString()} token limit. Use limit parameter or narrow your search.]`,
      });

      const finalTruncated = truncatedByLimit || truncateResult.truncated;

      logger.debug('AstGrep completed', {
        matchCount: limitedMatches.length,
        totalMatches,
        truncated: finalTruncated,
      });

      return {
        content: truncateResult.content,
        isError: false,
        details: {
          matches: limitedMatches,
          totalMatches,
          truncated: finalTruncated,
          ...(finalTruncated && { truncatedFrom: totalMatches }),
        },
      };
    } catch (error) {
      const err = error as Error;
      logger.error('AstGrep failed', { error: err.message });

      if (err.message.includes('Timeout')) {
        return {
          content: `Search timed out after ${timeout}ms. Try narrowing your search with specific path or language.`,
          isError: true,
          details: {},
        };
      }

      if (err.message.includes('cancel')) {
        return {
          content: 'Operation cancelled',
          isError: true,
          details: {},
        };
      }

      return {
        content: `Search failed: ${err.message}`,
        isError: true,
        details: {},
      };
    }
  }
}
