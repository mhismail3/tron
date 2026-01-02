/**
 * @fileoverview Input Area Component
 *
 * Text input for user prompts with macOS keyboard shortcuts.
 */
import React from 'react';
import { Box, Text } from 'ink';
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
  const handleSubmit = () => {
    if (value.trim() && !isProcessing) {
      onSubmit();
    }
  };

  return (
    <Box
      flexDirection="row"
      paddingX={1}
      borderStyle="single"
      borderColor={isProcessing ? 'gray' : 'green'}
    >
      <Text color={isProcessing ? 'gray' : 'green'}>&gt; </Text>
      {isProcessing ? (
        <Text color="gray">{value || 'Processing...'}</Text>
      ) : (
        <MacOSInput
          value={value}
          onChange={onChange}
          onSubmit={handleSubmit}
          placeholder="Enter your prompt..."
          onUpArrow={onUpArrow}
          onDownArrow={onDownArrow}
        />
      )}
    </Box>
  );
}
