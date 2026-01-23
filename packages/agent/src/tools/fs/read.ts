/**
 * @fileoverview Read tool for file reading
 *
 * Reads files with line numbers, offset, and limit support.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger } from '../../logging/logger.js';
import { getSettings } from '../../settings/index.js';
import { truncateOutput } from '../utils.js';

const logger = createLogger('tool:read');

// Get read tool settings (loaded lazily on first access)
function getReadSettings() {
  return getSettings().tools.read;
}

export interface ReadToolConfig {
  workingDirectory: string;
}

export class ReadTool implements TronTool {
  readonly name = 'Read';
  readonly description = 'Read the contents of a file. Returns the file content with line numbers.';
  readonly parameters = {
    type: 'object' as const,
    properties: {
      file_path: {
        type: 'string' as const,
        description: 'The absolute or relative path to the file to read',
      },
      offset: {
        type: 'number' as const,
        description: 'Line number to start reading from (0-indexed)',
      },
      limit: {
        type: 'number' as const,
        description: 'Maximum number of lines to read',
      },
    },
    required: ['file_path'] as string[],
  };

  private config: ReadToolConfig;

  constructor(config: ReadToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate required parameters (defense against truncated tool calls)
    if (!args.file_path || typeof args.file_path !== 'string') {
      return {
        content: 'Missing required parameter: file_path. Please provide the absolute or relative path to the file you want to read.',
        isError: true,
        details: { file_path: args.file_path },
      };
    }

    // Validate file_path is not just "/" or empty-ish
    const rawPath = args.file_path.trim();
    if (rawPath === '/' || rawPath === '.' || rawPath === '') {
      return {
        content: `Invalid file_path: "${args.file_path}". Please provide a specific file path, not a directory. Example: "/path/to/file.txt" or "src/index.ts"`,
        isError: true,
        details: { file_path: args.file_path },
      };
    }

    const settings = getReadSettings();
    const filePath = this.resolvePath(rawPath);
    const offset = (args.offset as number | undefined) ?? 0;
    const limit = (args.limit as number | undefined) ?? settings.defaultLimitLines;

    logger.debug('Reading file', { filePath, offset, limit });

    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n');
      const totalLines = lines.length;

      // Apply offset and limit
      const startLine = Math.max(0, offset);
      const endLine = Math.min(lines.length, startLine + limit);
      const selectedLines = lines.slice(startLine, endLine);

      // Format with line numbers and truncate long lines
      const maxLineLength = settings.maxLineLength;
      const formatted = selectedLines.map((line, idx) => {
        const lineNum = startLine + idx + 1;
        const truncatedLine = line.length > maxLineLength
          ? line.substring(0, maxLineLength) + '... [truncated]'
          : line;
        return `${String(lineNum).padStart(6)}→${truncatedLine}`;
      }).join('\n');

      // Apply token-based truncation
      const maxOutputTokens = settings.maxOutputTokens ?? 20000;
      const truncateResult = truncateOutput(formatted, maxOutputTokens, {
        preserveStartLines: 10,
        truncationMessage: `\n\n... [Output truncated: ${totalLines} total lines, showing ${selectedLines.length} lines. Output exceeded ${maxOutputTokens.toLocaleString()} token limit. Use offset/limit parameters to read specific sections.]`,
      });

      logger.debug('File read successfully', {
        filePath,
        totalLines,
        linesReturned: selectedLines.length,
        truncated: truncateResult.truncated,
      });

      return {
        content: truncateResult.content,
        isError: false,
        details: {
          filePath,
          totalLines,
          linesReturned: selectedLines.length,
          startLine: startLine + 1,
          endLine,
          truncated: truncateResult.truncated,
          ...(truncateResult.truncated && {
            originalTokens: truncateResult.originalTokens,
            finalTokens: truncateResult.finalTokens,
          }),
        },
      };
    } catch (error) {
      const err = error as NodeJS.ErrnoException;
      logger.error('File read failed', { filePath, error: err.message });

      if (err.code === 'ENOENT') {
        return {
          content: `File not found: ${filePath}`,
          isError: true,
          details: { filePath, errorCode: err.code },
        };
      }

      if (err.code === 'EACCES') {
        return {
          content: `Permission denied: ${filePath}`,
          isError: true,
          details: { filePath, errorCode: err.code },
        };
      }

      return {
        content: `Error reading file: ${err.message}`,
        isError: true,
        details: { filePath, errorCode: err.code },
      };
    }
  }

  private resolvePath(filePath: string): string {
    if (path.isAbsolute(filePath)) {
      return filePath;
    }
    return path.join(this.config.workingDirectory, filePath);
  }
}
