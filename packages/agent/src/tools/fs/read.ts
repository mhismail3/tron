/**
 * @fileoverview Read tool for file reading
 *
 * Reads files with line numbers, offset, and limit support.
 */

import * as fs from 'fs/promises';
import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger, categorizeError } from '../../logging/index.js';
import { getSettings } from '../../settings/index.js';
import {
  truncateOutput,
  resolvePath,
  validateRequiredString,
  validatePathNotRoot,
  formatFsError,
} from '../utils.js';

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
    // Validate required parameters
    const stringValidation = validateRequiredString(
      args, 'file_path', 'the path to the file you want to read',
      '"/path/to/file.txt" or "src/index.ts"'
    );
    if (!stringValidation.valid) return stringValidation.error!;

    const rawPath = (args.file_path as string).trim();
    const pathValidation = validatePathNotRoot(rawPath, 'file_path');
    if (!pathValidation.valid) return pathValidation.error!;

    const settings = getReadSettings();
    const filePath = resolvePath(rawPath, this.config.workingDirectory);
    const offset = (args.offset as number | undefined) ?? 0;
    const limit = (args.limit as number | undefined) ?? settings.defaultLimitLines;

    const startTime = Date.now();
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

      const duration = Date.now() - startTime;
      logger.info('File read completed', {
        filePath,
        bytesRead: content.length,
        totalLines,
        linesReturned: selectedLines.length,
        truncated: truncateResult.truncated,
        duration,
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
      const duration = Date.now() - startTime;
      const structuredError = categorizeError(error, { filePath, operation: 'read' });
      logger.error('File read failed', {
        filePath,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        duration,
      });
      return formatFsError(error, filePath, 'reading');
    }
  }
}
