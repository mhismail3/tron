/**
 * @fileoverview Tool Execution Component
 *
 * Displays tool execution status with animated spinner.
 * NO emojis - uses ASCII/Unicode characters.
 */
import React, { useState, useEffect } from 'react';
import { Text, Box } from 'ink';

// Spinner frames for running state
const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const FRAME_INTERVAL = 80;

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
  /** Optional additional details */
  details?: string;
}

/**
 * Truncate tool input for display, preserving key info
 */
function truncateInput(input: string, maxLength: number = 60): string {
  if (input.length <= maxLength) return input;
  return input.slice(0, maxLength - 3) + '...';
}

export function ToolExecution({
  toolName,
  status,
  toolInput,
  duration,
  details,
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

  return (
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
      {details && <Text color="gray">{details}</Text>}
    </Box>
  );
}
