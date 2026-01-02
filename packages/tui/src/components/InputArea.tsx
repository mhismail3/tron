/**
 * @fileoverview Input Area Component
 *
 * Multiline text input with macOS keyboard shortcuts.
 * Features:
 * - Dynamic height (expands with content)
 * - Max 20 visible lines with scroll
 * - Dark background styling (no borders)
 */
import React from 'react';
import { Box, Text, useStdout } from 'ink';
import { MacOSInput } from './MacOSInput.js';
import type { InputAreaProps } from '../types.js';

export function InputArea({
  value,
  onChange,
  onSubmit,
  isProcessing,
  onUpArrow,
  onDownArrow,
}: InputAreaProps): React.ReactElement {
  const { stdout } = useStdout();
  const terminalWidth = stdout?.columns ?? 80;

  const handleSubmit = () => {
    if (value.trim() && !isProcessing) {
      onSubmit();
    }
  };

  // Calculate max visible lines for display
  const maxVisibleLines = 20;

  return (
    <Box
      flexDirection="column"
      paddingX={1}
      paddingY={0}
    >
      <Box flexDirection="row">
        <Text color={isProcessing ? 'gray' : 'green'} bold>&gt; </Text>
        <Box flexGrow={1}>
          {isProcessing ? (
            <Text color="gray">{value || 'Processing...'}</Text>
          ) : (
            <MacOSInput
              value={value}
              onChange={onChange}
              onSubmit={handleSubmit}
              placeholder="Write your prompt... (Shift+Enter for new line)"
              onHistoryUp={onUpArrow}
              onHistoryDown={onDownArrow}
              maxVisibleLines={maxVisibleLines}
              terminalWidth={terminalWidth - 4}
            />
          )}
        </Box>
      </Box>
    </Box>
  );
}
