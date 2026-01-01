/**
 * @fileoverview Edit tool for file editing
 *
 * Performs search and replace operations on files.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:edit');

export interface EditToolConfig {
  workingDirectory: string;
}

export class EditTool implements TronTool {
  readonly name = 'Edit';
  readonly description = 'Edit a file by replacing old_string with new_string. Requires exact match.';
  readonly parameters = {
    type: 'object' as const,
    properties: {
      file_path: {
        type: 'string' as const,
        description: 'The absolute or relative path to the file to edit',
      },
      old_string: {
        type: 'string' as const,
        description: 'The exact string to search for and replace',
      },
      new_string: {
        type: 'string' as const,
        description: 'The string to replace old_string with',
      },
      replace_all: {
        type: 'boolean' as const,
        description: 'Replace all occurrences (default: false)',
        default: false,
      },
    },
    required: ['file_path', 'old_string', 'new_string'] as string[],
  };

  private config: EditToolConfig;

  constructor(config: EditToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    const filePath = this.resolvePath(args.file_path as string);
    const oldString = args.old_string as string;
    const newString = args.new_string as string;
    const replaceAll = (args.replace_all as boolean) ?? false;

    logger.debug('Editing file', { filePath, replaceAll });

    // Validate inputs
    if (oldString === newString) {
      return {
        content: 'Error: old_string and new_string are the same. No changes needed.',
        isError: true,
        details: { filePath },
      };
    }

    try {
      const content = await fs.readFile(filePath, 'utf-8');

      // Count occurrences
      const occurrences = this.countOccurrences(content, oldString);

      if (occurrences === 0) {
        return {
          content: `Error: old_string not found in file. The exact string "${this.truncate(oldString, 50)}" does not exist in ${filePath}`,
          isError: true,
          details: { filePath, occurrences: 0 },
        };
      }

      // If multiple occurrences and not replace_all, error
      if (occurrences > 1 && !replaceAll) {
        return {
          content: `Error: old_string appears multiple times (${occurrences} occurrences). Use replace_all: true to replace all occurrences, or provide more context to make the match unique.`,
          isError: true,
          details: { filePath, occurrences },
        };
      }

      // Perform replacement
      let newContent: string;
      let replacements: number;

      if (replaceAll) {
        newContent = content.split(oldString).join(newString);
        replacements = occurrences;
      } else {
        newContent = content.replace(oldString, newString);
        replacements = 1;
      }

      // Write the file
      await fs.writeFile(filePath, newContent, 'utf-8');

      logger.info('File edited successfully', {
        filePath,
        replacements,
      });

      return {
        content: `Successfully replaced ${replacements} occurrence${replacements > 1 ? 's' : ''} in ${filePath}`,
        isError: false,
        details: {
          filePath,
          replacements,
          oldStringPreview: this.truncate(oldString, 50),
          newStringPreview: this.truncate(newString, 50),
        },
      };
    } catch (error) {
      const err = error as NodeJS.ErrnoException;
      logger.error('File edit failed', { filePath, error: err.message });

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
        content: `Error editing file: ${err.message}`,
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

  private countOccurrences(str: string, search: string): number {
    let count = 0;
    let pos = 0;
    while ((pos = str.indexOf(search, pos)) !== -1) {
      count++;
      pos += search.length;
    }
    return count;
  }

  private truncate(str: string, maxLen: number): string {
    if (str.length <= maxLen) return str;
    return str.substring(0, maxLen) + '...';
  }
}
