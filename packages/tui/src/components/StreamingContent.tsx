/**
 * @fileoverview Streaming Content Component
 *
 * Displays text content with a cursor when streaming.
 */
import React from 'react';
import { Text, Box } from 'ink';

export interface StreamingContentProps {
  /** The content to display */
  content: string;
  /** Whether content is still streaming */
  isStreaming: boolean;
  /** Color for the text */
  color?: string;
}

export function StreamingContent({
  content,
  isStreaming,
  color,
}: StreamingContentProps): React.ReactElement {
  if (!content && !isStreaming) {
    return <Text></Text>;
  }

  return (
    <Box flexDirection="column">
      <Text color={color}>
        {content}
        {isStreaming && <Text color="gray">█</Text>}
      </Text>
    </Box>
  );
}
