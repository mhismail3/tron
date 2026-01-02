/**
 * @fileoverview Tool Execution Component
 *
 * Displays tool execution status with animated spinner.
 * Shows truncated output for completed tools.
 * NO emojis - uses ASCII/Unicode characters.
 */
import React, { useState, useEffect } from 'react';
import { Text, Box } from 'ink';

// Spinner frames for running state
const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const FRAME_INTERVAL = 80;

// Display configuration
const MAX_INPUT_LENGTH = 60;
const MAX_OUTPUT_LINES = 3;
const MAX_OUTPUT_LINE_LENGTH = 80;

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
}: ToolExecutionProps): React.ReactElement {
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    if (status !== 'running') return;

    const timer = setInterval(() => {
      setFrameIndex((current) => (current + 1) % SPINNER_FRAMES.length);
    }, FRAME_INTERVAL);

    return () => clearInterval(timer);
  }, [status]);

  const getStatusIndicator = () => {
    switch (status) {
      case 'running':
        return (
          <Text color="yellow">{SPINNER_FRAMES[frameIndex] ?? SPINNER_FRAMES[0]}</Text>
        );
      case 'success':
        return <Text color="green">+</Text>;
      case 'error':
        return <Text color="red">!</Text>;
    }
  };

  const getStatusColor = () => {
    switch (status) {
      case 'running':
        return 'yellow';
      case 'success':
        return 'green';
      case 'error':
        return 'red';
    }
  };

  // Format output lines (more lines if expanded)
  const outputLines = formatOutput(output ?? '', expanded ? 10 : MAX_OUTPUT_LINES);
  const hasOutput = outputLines.length > 0;

  return (
    <Box flexDirection="column">
      {/* Main tool execution line */}
      <Box flexDirection="row" gap={1}>
        {getStatusIndicator()}
        <Text color={getStatusColor()} bold>
          {toolName}
        </Text>
        {toolInput && (
          <Text color="gray">{truncateInput(toolInput)}</Text>
        )}
        {status === 'success' && duration !== undefined && (
          <Text color="gray">({duration}ms)</Text>
        )}
      </Box>

      {/* Output preview (indented under the tool) */}
      {hasOutput && status !== 'running' && (
        <Box flexDirection="column" marginLeft={2}>
          {outputLines.map((line, index) => (
            <Text key={index} color="gray" dimColor>
              {line}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  );
}
