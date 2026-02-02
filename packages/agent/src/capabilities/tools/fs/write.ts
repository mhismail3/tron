/**
 * @fileoverview Write tool for file writing
 *
 * Writes content to files, creating directories as needed.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger, categorizeError } from '@infrastructure/logging/index.js';
import {
  resolvePath,
  validateRequiredString,
  formatFsError,
} from '../utils.js';

const logger = createLogger('tool:write');

export interface WriteToolConfig {
  workingDirectory: string;
}

export class WriteTool implements TronTool {
  readonly name = 'Write';
  readonly description = 'Write content to a file. Creates parent directories if they do not exist.';
  readonly parameters = {
    type: 'object' as const,
    properties: {
      file_path: {
        type: 'string' as const,
        description: 'The absolute or relative path to the file to write',
      },
      content: {
        type: 'string' as const,
        description: 'The content to write to the file',
      },
    },
    required: ['file_path', 'content'] as string[],
  };

  private config: WriteToolConfig;

  constructor(config: WriteToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate required parameters
    const pathValidation = validateRequiredString(args, 'file_path', 'the path to write to');
    if (!pathValidation.valid) return pathValidation.error!;

    if (args.content === undefined || args.content === null) {
      return {
        content: 'Missing required parameter: content. The tool call may have been truncated.',
        isError: true,
      };
    }

    const filePath = resolvePath(args.file_path as string, this.config.workingDirectory);
    const content = args.content as string;

    const startTime = Date.now();
    logger.debug('Writing file', { filePath, contentLength: content.length });

    try {
      // Check if file exists (for reporting)
      let fileExists = false;
      try {
        await fs.access(filePath);
        fileExists = true;
      } catch {
        // File doesn't exist
      }

      // Ensure parent directory exists
      const dir = path.dirname(filePath);
      await fs.mkdir(dir, { recursive: true });

      // Write the file
      await fs.writeFile(filePath, content, 'utf-8');

      const bytesWritten = Buffer.byteLength(content);

      const duration = Date.now() - startTime;
      logger.info('File write completed', {
        filePath,
        bytesWritten,
        created: !fileExists,
        duration,
      });

      return {
        content: fileExists
          ? `Successfully wrote ${bytesWritten} bytes to ${filePath} (overwritten)`
          : `Successfully created ${filePath} with ${bytesWritten} bytes`,
        isError: false,
        details: {
          filePath,
          bytesWritten,
          created: !fileExists,
        },
      };
    } catch (error) {
      const duration = Date.now() - startTime;
      const structuredError = categorizeError(error, { filePath, operation: 'write' });
      logger.error('File write failed', {
        filePath,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        duration,
      });
      return formatFsError(error, filePath, 'writing');
    }
  }
}
