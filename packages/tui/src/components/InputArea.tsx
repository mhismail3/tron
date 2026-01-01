/**
 * @fileoverview Input Area Component
 *
 * Text input for user prompts.
 */
import React from 'react';
import { Box, Text } from 'ink';
import TextInput from 'ink-text-input';
import type { InputAreaProps } from '../types.js';

export function InputArea({
  value,
  onChange,
  onSubmit,
  isProcessing,
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
      <Text color={isProcessing ? 'gray' : 'green'}>❯ </Text>
      {isProcessing ? (
        <Text color="gray">{value || 'Processing...'}</Text>
      ) : (
        <TextInput
          value={value}
          onChange={onChange}
          onSubmit={handleSubmit}
          placeholder="Enter your prompt..."
        />
      )}
    </Box>
  );
}
