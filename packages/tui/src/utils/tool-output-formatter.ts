/**
 * @fileoverview Tool Output Formatter Utilities
 *
 * Provides tool-specific output formatting for display in the TUI.
 * Each tool gets a concise summary and truncated preview, similar to Claude Code:
 * - Read: "Read X lines"
 * - Write: "Wrote X lines"
 * - Edit: "+X lines, -Y lines"
 * - Bash: "X lines" with preview
 */

export interface FormattedOutput {
  summary: string;
  preview: string[];
  totalLines: number;
  truncated: boolean;
}

export interface TruncatedResult {
  lines: string[];
  totalLines: number;
  truncated: boolean;
}

const DEFAULT_MAX_LINES = 3;
const DEFAULT_MAX_LINE_LENGTH = 80;

/**
 * Count non-empty lines in a string
 */
export function countLines(content: string): number {
  if (!content || content.trim().length === 0) return 0;
  return content.split('\n').filter(line => line.trim().length > 0).length;
}

/**
 * Truncate output to specified number of lines
 */
export function truncateOutput(
  content: string,
  maxLines: number = DEFAULT_MAX_LINES,
  maxLineLength: number = DEFAULT_MAX_LINE_LENGTH
): TruncatedResult {
  if (!content || content.trim().length === 0) {
    return { lines: [], totalLines: 0, truncated: false };
  }

  // Normalize line endings and split
  const allLines = content
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .split('\n')
    .filter(line => line.trim().length > 0);

  const totalLines = allLines.length;

  // Take first maxLines and truncate each line
  const truncatedLines = allLines.slice(0, maxLines).map(line => {
    if (line.length > maxLineLength) {
      return line.slice(0, maxLineLength) + '...';
    }
    return line;
  });

  return {
    lines: truncatedLines,
    totalLines,
    truncated: totalLines > maxLines,
  };
}

/**
 * Format Read tool output
 */
export function formatReadOutput(
  content: string,
  _filePath?: string
): FormattedOutput {
  const safeContent = content ?? '';

  if (safeContent.trim().length === 0) {
    return {
      summary: 'Empty file',
      preview: [],
      totalLines: 0,
      truncated: false,
    };
  }

  const lineCount = countLines(safeContent);
  const { lines, truncated } = truncateOutput(safeContent);

  return {
    summary: `Read ${lineCount} line${lineCount === 1 ? '' : 's'}`,
    preview: lines,
    totalLines: lineCount,
    truncated,
  };
}

/**
 * Format Write tool output
 */
export function formatWriteOutput(
  content: string,
  _filePath?: string,
  isNewFile: boolean = false
): FormattedOutput {
  const safeContent = content ?? '';
  const lineCount = countLines(safeContent);
  const { lines, truncated } = truncateOutput(safeContent);

  const verb = isNewFile ? 'Created file with' : 'Wrote';
  return {
    summary: `${verb} ${lineCount} line${lineCount === 1 ? '' : 's'}`,
    preview: lines,
    totalLines: lineCount,
    truncated,
  };
}

export interface EditStats {
  added?: number;
  removed?: number;
  replaceAll?: boolean;
  occurrences?: number;
  diffOutput?: string;
}

/**
 * Parse diff-style output to count added/removed lines
 */
function parseDiffOutput(diffOutput: string): { added: number; removed: number } {
  const lines = diffOutput.split('\n');
  let added = 0;
  let removed = 0;

  for (const line of lines) {
    // Skip diff headers
    if (line.startsWith('---') || line.startsWith('+++') || line.startsWith('@@')) {
      continue;
    }
    // Count additions (lines starting with +, but not ++)
    if (line.startsWith('+') && !line.startsWith('++')) {
      added++;
    }
    // Count removals (lines starting with -, but not --)
    if (line.startsWith('-') && !line.startsWith('--')) {
      removed++;
    }
  }

  return { added, removed };
}

/**
 * Format Edit tool output with diff preview
 */
export function formatEditOutput(stats: EditStats): FormattedOutput {
  let added = stats.added ?? 0;
  let removed = stats.removed ?? 0;

  // Parse diff output if provided
  if (stats.diffOutput) {
    const parsed = parseDiffOutput(stats.diffOutput);
    added = parsed.added;
    removed = parsed.removed;
  }

  // Build summary
  const parts: string[] = [];

  if (stats.replaceAll && stats.occurrences !== undefined) {
    parts.push(`${stats.occurrences} occurrence${stats.occurrences === 1 ? '' : 's'}`);
  }

  if (added > 0) {
    parts.push(`+${added} line${added === 1 ? '' : 's'}`);
  }

  if (removed > 0) {
    parts.push(`-${removed} line${removed === 1 ? '' : 's'}`);
  }

  const summary = parts.length > 0 ? parts.join(', ') : 'No changes';

  // Extract diff lines for preview (the actual +/- lines)
  let preview: string[] = [];
  let totalLines = 0;
  let truncated = false;

  if (stats.diffOutput) {
    const diffLines = stats.diffOutput.split('\n').filter(line => line.length > 0);
    totalLines = diffLines.length;

    // Include diff lines in preview (up to 10 lines for diffs)
    const maxDiffLines = 10;
    preview = diffLines.slice(0, maxDiffLines).map(line => {
      // Truncate long lines
      if (line.length > 100) {
        return line.slice(0, 97) + '...';
      }
      return line;
    });
    truncated = diffLines.length > maxDiffLines;
  }

  return {
    summary,
    preview,
    totalLines,
    truncated,
  };
}

export interface BashOptions {
  exitCode?: number;
}

/**
 * Format Bash tool output
 */
export function formatBashOutput(
  output: string,
  options: BashOptions = {}
): FormattedOutput {
  const safeOutput = output ?? '';

  if (safeOutput.trim().length === 0) {
    return {
      summary: 'No output',
      preview: [],
      totalLines: 0,
      truncated: false,
    };
  }

  const { lines, totalLines, truncated } = truncateOutput(safeOutput);

  // Build summary
  let summary = `${totalLines} line${totalLines === 1 ? '' : 's'}`;

  // Add exit code if non-zero
  if (options.exitCode !== undefined && options.exitCode !== 0) {
    summary += ` (exit ${options.exitCode})`;
  }

  return {
    summary,
    preview: lines,
    totalLines,
    truncated,
  };
}

/**
 * Format Glob tool output
 */
export function formatGlobOutput(output: string): FormattedOutput {
  const safeOutput = output ?? '';

  if (safeOutput.trim().length === 0) {
    return {
      summary: 'No files found',
      preview: [],
      totalLines: 0,
      truncated: false,
    };
  }

  const fileCount = countLines(safeOutput);
  const { lines, truncated } = truncateOutput(safeOutput);

  return {
    summary: `Found ${fileCount} file${fileCount === 1 ? '' : 's'}`,
    preview: lines,
    totalLines: fileCount,
    truncated,
  };
}

/**
 * Format Grep tool output
 */
export function formatGrepOutput(output: string): FormattedOutput {
  const safeOutput = output ?? '';

  if (safeOutput.trim().length === 0) {
    return {
      summary: 'No matches found',
      preview: [],
      totalLines: 0,
      truncated: false,
    };
  }

  const matchCount = countLines(safeOutput);
  const { lines, truncated } = truncateOutput(safeOutput);

  return {
    summary: `Found ${matchCount} match${matchCount === 1 ? '' : 'es'}`,
    preview: lines,
    totalLines: matchCount,
    truncated,
  };
}

export interface FormatOptions {
  isError?: boolean;
  filePath?: string;
  exitCode?: number;
  editStats?: EditStats;
}

/**
 * Unified entry point for formatting tool output
 * Routes to the appropriate formatter based on tool name
 */
export function formatToolOutput(
  toolName: string,
  content: string,
  options: FormatOptions = {}
): FormattedOutput {
  const safeContent = content ?? '';
  const normalizedName = toolName.toLowerCase();

  // Handle error outputs
  if (options.isError) {
    const { lines, totalLines, truncated } = truncateOutput(safeContent);
    return {
      summary: `Error: ${lines[0]?.slice(0, 50) ?? 'Unknown error'}`,
      preview: lines,
      totalLines,
      truncated,
    };
  }

  switch (normalizedName) {
    case 'read':
      return formatReadOutput(safeContent, options.filePath);

    case 'write':
      return formatWriteOutput(safeContent, options.filePath);

    case 'edit':
      if (options.editStats) {
        return formatEditOutput(options.editStats);
      }
      // Fallback: try to parse as diff
      return formatEditOutput({ diffOutput: safeContent });

    case 'bash':
      return formatBashOutput(safeContent, { exitCode: options.exitCode });

    case 'glob':
      return formatGlobOutput(safeContent);

    case 'grep':
      return formatGrepOutput(safeContent);

    default:
      // Generic fallback for unknown tools
      return formatBashOutput(safeContent);
  }
}
