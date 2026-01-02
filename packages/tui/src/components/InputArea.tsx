/**
 * @fileoverview Input Area Component
 *
 * Text input for user prompts with enhanced editing support.
 * Supports: Ctrl+W (delete word), Ctrl+U (delete to line start),
 * Ctrl+K (delete to line end), Ctrl+A/E (line navigation),
 * Cmd+Left/Right (line navigation on Mac), and more.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { EnhancedInput } from './EnhancedInput.js';
import type { InputAreaProps } from '../types.js';

export function InputArea({
  value,
  onChange,
  onSubmit,
  isProcessing,
  onHistoryUp,
  onHistoryDown,
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
        <EnhancedInput
          value={value}
          onChange={onChange}
          onSubmit={handleSubmit}
          placeholder="Enter your prompt..."
          onHistoryUp={onHistoryUp}
          onHistoryDown={onHistoryDown}
        />
      )}
    </Box>
  );
}
