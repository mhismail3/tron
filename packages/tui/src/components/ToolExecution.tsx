/**
 * @fileoverview Tool Execution Component
 *
 * Displays tool execution status with elegant Unicode icons.
 * Shows truncated output for completed tools with diff highlighting.
 */
import React from 'react';
import { Text, Box } from 'ink';
import { inkColors, icons, palette } from '../theme.js';
import { formatTokens } from '@tron/agent';

// Display configuration
const MAX_INPUT_LENGTH = 60;
const MAX_OUTPUT_LINES = 8;
const MAX_OUTPUT_LINE_LENGTH = 100;

/**
 * Detect if a line is part of a unified diff and return its type
 */
function getDiffLineType(line: string): 'added' | 'removed' | 'hunk' | 'context' | 'normal' {
  // Check for diff-specific patterns
  if (line.startsWith('@@') && line.includes('@@')) {
    return 'hunk';
  }
  // Added line (+ but not ++ header)
  if (line.startsWith('+') && !line.startsWith('++')) {
    return 'added';
  }
  // Removed line (- but not -- header)
  if (line.startsWith('-') && !line.startsWith('--')) {
    return 'removed';
  }
  // Context line in diff (starts with space, common in unified diff)
  if (line.startsWith(' ') && line.length > 1) {
    return 'context';
  }
  return 'normal';
}

/**
 * Check if output contains diff content
 */
function containsDiff(lines: string[]): boolean {
  return lines.some(line =>
    line.startsWith('@@') ||
    (line.startsWith('+') && !line.startsWith('++')) ||
    (line.startsWith('-') && !line.startsWith('--'))
  );
}

/**
 * Render a single diff line with appropriate coloring
 */
function DiffLine({ line, index }: { line: string; index: number }): React.ReactElement {
  const lineType = getDiffLineType(line);

  switch (lineType) {
    case 'added':
      return (
        <Text key={index} color={palette.success}>
          {line}
        </Text>
      );
    case 'removed':
      return (
        <Text key={index} color={palette.error}>
          {line}
        </Text>
      );
    case 'hunk':
      return (
        <Text key={index} color={palette.info}>
          {line}
        </Text>
      );
    case 'context':
      return (
        <Text key={index} color={inkColors.dim}>
          {line}
        </Text>
      );
    default:
      return (
        <Text key={index} color={inkColors.dim}>
          {line}
        </Text>
      );
  }
}

export type ToolStatus = 'running' | 'success' | 'error';

export interface ToolExecutionProps {
  /** Name of the tool being executed */
  toolName: string;
  /** Current execution status */
  status: ToolStatus;
  /** The command/input being executed (e.g., "ls -la" for Bash) */
  toolInput?: string;
  /** Duration in milliseconds (for completed tools) */
  duration?: number;
  /** Tool output/result content */
  output?: string;
  /** Whether to show expanded output (more lines) */
  expanded?: boolean;
  /** Token usage for this tool operation (per-turn, not cumulative) */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

/**
 * Truncate tool input for display, preserving key info
 */
function truncateInput(input: string, maxLength: number = MAX_INPUT_LENGTH): string {
  if (input.length <= maxLength) return input;
  return input.slice(0, maxLength - 3) + '...';
}

/**
 * Truncate and format tool output for multi-line display
 */
function formatOutput(output: string, maxLines: number = MAX_OUTPUT_LINES): string[] {
  if (!output || output.trim().length === 0) return [];

  // Split into lines and filter empty ones
  const lines = output.split('\n').filter(line => line.trim().length > 0);

  // Take only maxLines, truncate each line if needed
  const truncatedLines = lines.slice(0, maxLines).map(line => {
    if (line.length > MAX_OUTPUT_LINE_LENGTH) {
      return line.slice(0, MAX_OUTPUT_LINE_LENGTH - 3) + '...';
    }
    return line;
  });

  // Add indicator if there are more lines
  if (lines.length > maxLines) {
    const remaining = lines.length - maxLines;
    truncatedLines.push(`... (${remaining} more line${remaining === 1 ? '' : 's'})`);
  }

  return truncatedLines;
}

export function ToolExecution({
  toolName,
  status,
  toolInput,
  duration,
  output,
  expanded = false,
  tokenUsage,
}: ToolExecutionProps): React.ReactElement {

  const getStatusIndicator = () => {
    switch (status) {
      case 'running':
        return (
          <Text color={inkColors.toolRunning}>
            {icons.toolRunning}
          </Text>
        );
      case 'success':
        return <Text color={inkColors.toolSuccess}>{icons.toolSuccess}</Text>;
      case 'error':
        return <Text color={inkColors.toolError}>{icons.toolError}</Text>;
    }
  };

  const getStatusColor = () => {
    switch (status) {
      case 'running':
        return inkColors.toolRunning;
      case 'success':
        return inkColors.toolSuccess;
      case 'error':
        return inkColors.toolError;
    }
  };

  // Format output lines (more lines if expanded)
  const outputLines = formatOutput(output ?? '', expanded ? 15 : MAX_OUTPUT_LINES);
  const hasOutput = outputLines.length > 0;

  // Check if output contains diff content for syntax highlighting
  const isDiffOutput = hasOutput && containsDiff(outputLines);

  return (
    <Box flexDirection="column">
      {/* Main tool execution line */}
      <Box flexDirection="row" gap={1}>
        {getStatusIndicator()}
        <Text color={getStatusColor()} bold>
          {toolName}
        </Text>
        {toolInput && (
          <Text color={inkColors.dim}>{truncateInput(toolInput)}</Text>
        )}
        {status === 'success' && duration !== undefined && (
          <Text color={inkColors.dim}>({duration}ms)</Text>
        )}
        {tokenUsage && (
          <Text color={inkColors.dim}>
            {formatTokens(tokenUsage.inputTokens)}/{formatTokens(tokenUsage.outputTokens)}
          </Text>
        )}
      </Box>

      {/* Output preview (indented under the tool) */}
      {hasOutput && status !== 'running' && (
        <Box flexDirection="column" marginLeft={2}>
          {isDiffOutput ? (
            // Render diff with syntax highlighting
            outputLines.map((line, index) => (
              <DiffLine key={index} line={line} index={index} />
            ))
          ) : (
            // Regular output - all dim
            outputLines.map((line, index) => (
              <Text key={index} color={inkColors.dim}>
                {line}
              </Text>
            ))
          )}
        </Box>
      )}
    </Box>
  );
}
