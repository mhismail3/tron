/**
 * @fileoverview Prompt Box Component
 *
 * Input area with bordered box styling for visual distinction.
 * Design: Bordered box with responsive width handling.
 */
import React from 'react';
import { Box, useStdout } from 'ink';
import { MacOSInput } from './MacOSInput.js';
import type { InputAreaProps } from '../types.js';

export function PromptBox({
  value,
  onChange,
  onSubmit,
  isProcessing,
  onUpArrow,
  onDownArrow,
  onCtrlC,
}: InputAreaProps): React.ReactElement {
  const { stdout } = useStdout();
  const terminalWidth = stdout?.columns ?? 80;

  const handleSubmit = () => {
    if (value.trim() && !isProcessing) {
      onSubmit();
    }
  };

  // Responsive breakpoints
  const isNarrow = terminalWidth < 50;
  const maxVisibleLines = isNarrow ? 10 : 20;

  // Calculate available width for input
  // Account for: border (2) + paddingX (2) + marginX (2) + prompt "> " (2) = 8
  const inputWidth = Math.max(20, terminalWidth - 8);

  // Placeholder text based on width
  const placeholder = isNarrow
    ? 'Type here...'
    : 'Write your prompt... (Shift+Enter for new line)';

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor="gray"
      paddingX={1}
      paddingY={0}
      marginX={1}
    >
      <MacOSInput
        value={value}
        onChange={onChange}
        onSubmit={handleSubmit}
        placeholder={placeholder}
        onHistoryUp={onUpArrow}
        onHistoryDown={onDownArrow}
        onCtrlC={onCtrlC}
        maxVisibleLines={maxVisibleLines}
        terminalWidth={inputWidth}
        promptPrefix="> "
        promptColor="green"
        continuationPrefix="  "
        isProcessing={isProcessing}
      />
    </Box>
  );
}
