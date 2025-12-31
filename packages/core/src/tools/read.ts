/**
 * @fileoverview Read tool for file reading
 *
 * Reads files with line numbers, offset, and limit support.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:read');

const MAX_LINE_LENGTH = 2000;
const DEFAULT_LIMIT = 2000;

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
        type: 'string',
        description: 'The absolute or relative path to the file to read',
      },
      offset: {
        type: 'number',
        description: 'Line number to start reading from (0-indexed)',
      },
      limit: {
        type: 'number',
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
    const filePath = this.resolvePath(args.file_path as string);
    const offset = (args.offset as number | undefined) ?? 0;
    const limit = (args.limit as number | undefined) ?? DEFAULT_LIMIT;

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
      const formatted = selectedLines.map((line, idx) => {
        const lineNum = startLine + idx + 1;
        const truncatedLine = line.length > MAX_LINE_LENGTH
          ? line.substring(0, MAX_LINE_LENGTH) + '... [truncated]'
          : line;
        return `${String(lineNum).padStart(6)}→${truncatedLine}`;
      }).join('\n');

      logger.debug('File read successfully', {
        filePath,
        totalLines,
        linesReturned: selectedLines.length,
      });

      return {
        content: formatted,
        isError: false,
        details: {
          filePath,
          totalLines,
          linesReturned: selectedLines.length,
          startLine: startLine + 1,
          endLine,
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
