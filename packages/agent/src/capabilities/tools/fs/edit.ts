/**
 * @fileoverview Edit tool for file editing
 *
 * Performs search and replace operations on files.
 * Returns unified diff output showing exactly what changed.
 */

import * as fs from 'fs/promises';
import type { TronTool, TronToolResult, ToolExecutionOptions } from '@core/types/index.js';
import { createLogger, categorizeError } from '@infrastructure/logging/index.js';
import {
  resolvePath,
  validateRequiredString,
  formatFsError,
} from '../utils.js';

/**
 * Generate a unified diff between old and new strings.
 * Shows context around the change with +/- prefixes.
 */
function generateUnifiedDiff(
  oldStr: string,
  newStr: string,
  contextLines: number = 3
): string {
  const oldLines = oldStr.split('\n');
  const newLines = newStr.split('\n');

  const diffLines: string[] = [];

  // Find the first differing line
  let firstDiff = 0;
  while (
    firstDiff < oldLines.length &&
    firstDiff < newLines.length &&
    oldLines[firstDiff] === newLines[firstDiff]
  ) {
    firstDiff++;
  }

  // Find the last differing line (from the end)
  let oldEnd = oldLines.length - 1;
  let newEnd = newLines.length - 1;
  while (
    oldEnd > firstDiff &&
    newEnd > firstDiff &&
    oldLines[oldEnd] === newLines[newEnd]
  ) {
    oldEnd--;
    newEnd--;
  }

  // Calculate context boundaries
  const contextStart = Math.max(0, firstDiff - contextLines);
  const oldContextEnd = Math.min(oldLines.length - 1, oldEnd + contextLines);

  // Add hunk header
  const oldStart = contextStart + 1;
  const oldCount = oldEnd - contextStart + 1 + Math.min(contextLines, oldLines.length - oldEnd - 1);
  const newStart = contextStart + 1;
  const newCount = newEnd - contextStart + 1 + Math.min(contextLines, newLines.length - newEnd - 1);
  diffLines.push(`@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`);

  // Add context before
  for (let i = contextStart; i < firstDiff; i++) {
    diffLines.push(` ${oldLines[i]}`);
  }

  // Add removed lines
  for (let i = firstDiff; i <= oldEnd; i++) {
    diffLines.push(`-${oldLines[i]}`);
  }

  // Add added lines
  for (let i = firstDiff; i <= newEnd; i++) {
    diffLines.push(`+${newLines[i]}`);
  }

  // Add context after
  const afterStart = oldEnd + 1;
  for (let i = afterStart; i <= oldContextEnd; i++) {
    diffLines.push(` ${oldLines[i]}`);
  }

  return diffLines.join('\n');
}

const logger = createLogger('tool:edit');

export interface EditToolConfig {
  workingDirectory: string;
}

export class EditTool implements TronTool {
  readonly name = 'Edit';
  readonly executionContract = 'options' as const;
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

  async execute(args: Record<string, unknown>, _options?: ToolExecutionOptions): Promise<TronToolResult> {
    // Validate required parameters
    const pathValidation = validateRequiredString(args, 'file_path', 'the path to the file to edit');
    if (!pathValidation.valid) return pathValidation.error!;

    if (args.old_string === undefined || args.old_string === null) {
      return {
        content: 'Missing required parameter: old_string. The tool call may have been truncated.',
        isError: true,
      };
    }
    if (args.new_string === undefined || args.new_string === null) {
      return {
        content: 'Missing required parameter: new_string. The tool call may have been truncated.',
        isError: true,
      };
    }

    const filePath = resolvePath(args.file_path as string, this.config.workingDirectory);
    const oldString = args.old_string as string;
    const newString = args.new_string as string;
    const replaceAll = (args.replace_all as boolean) ?? false;

    const startTime = Date.now();
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

      const duration = Date.now() - startTime;
      logger.info('File edit completed', {
        filePath,
        replacements,
        oldStringLength: oldString.length,
        newStringLength: newString.length,
        duration,
      });

      // Generate unified diff for display
      const diff = generateUnifiedDiff(oldString, newString, 2);

      // Build result content with diff
      const resultContent = [
        `Successfully replaced ${replacements} occurrence${replacements > 1 ? 's' : ''} in ${filePath}`,
        '',
        diff,
      ].join('\n');

      return {
        content: resultContent,
        isError: false,
        details: {
          filePath,
          replacements,
          oldStringPreview: this.truncate(oldString, 50),
          newStringPreview: this.truncate(newString, 50),
          diff,
        },
      };
    } catch (error) {
      const duration = Date.now() - startTime;
      const structuredError = categorizeError(error, { filePath, operation: 'edit' });
      logger.error('File edit failed', {
        filePath,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        duration,
      });
      return formatFsError(error, filePath, 'editing');
    }
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
