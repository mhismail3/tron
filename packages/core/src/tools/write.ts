/**
 * @fileoverview Write tool for file writing
 *
 * Writes content to files, creating directories as needed.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

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
        type: 'string',
        description: 'The absolute or relative path to the file to write',
      },
      content: {
        type: 'string',
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
    const filePath = this.resolvePath(args.file_path as string);
    const content = args.content as string;

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

      logger.info('File written successfully', {
        filePath,
        bytesWritten,
        created: !fileExists,
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
      const err = error as NodeJS.ErrnoException;
      logger.error('File write failed', { filePath, error: err.message });

      if (err.code === 'EACCES') {
        return {
          content: `Permission denied: ${filePath}`,
          isError: true,
          details: { filePath, errorCode: err.code },
        };
      }

      return {
        content: `Error writing file: ${err.message}`,
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
