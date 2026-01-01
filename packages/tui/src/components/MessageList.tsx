/**
 * @fileoverview Message List Component
 *
 * Displays the conversation messages.
 */
import React from 'react';
import { Box, Text } from 'ink';
import type { MessageListProps, DisplayMessage } from '../types.js';

export function MessageList({
  messages,
  isProcessing,
  activeTool,
}: MessageListProps): React.ReactElement {
  return (
    <Box flexDirection="column" gap={1}>
      {messages.map((message) => (
        <MessageItem key={message.id} message={message} />
      ))}

      {/* Processing indicator */}
      {isProcessing && (
        <Box>
          <Text color="yellow">
            {activeTool ? `⚙️  Running ${activeTool}...` : '🤔 Thinking...'}
          </Text>
        </Box>
      )}
    </Box>
  );
}

interface MessageItemProps {
  message: DisplayMessage;
}

function MessageItem({ message }: MessageItemProps): React.ReactElement {
  const getRoleDisplay = () => {
    switch (message.role) {
      case 'user':
        return { prefix: '❯', color: 'cyan' as const };
      case 'assistant':
        return { prefix: '◆', color: 'green' as const };
      case 'system':
        return { prefix: '●', color: 'gray' as const };
      case 'tool':
        return { prefix: '⚙', color: 'yellow' as const };
      default:
        return { prefix: '?', color: 'white' as const };
    }
  };

  const { prefix, color } = getRoleDisplay();

  // Truncate long content for display
  const maxContentLength = 500;
  const displayContent =
    message.content.length > maxContentLength
      ? message.content.slice(0, maxContentLength) + '...'
      : message.content;

  // For tool messages, show tool name
  if (message.role === 'tool') {
    const statusIcon =
      message.toolStatus === 'success'
        ? '✓'
        : message.toolStatus === 'error'
        ? '✗'
        : '⋯';
    const statusColor =
      message.toolStatus === 'success'
        ? 'green'
        : message.toolStatus === 'error'
        ? 'red'
        : 'yellow';

    return (
      <Box flexDirection="row" gap={1}>
        <Text color={color}>{prefix}</Text>
        <Text color="yellow" bold>
          {message.toolName}
        </Text>
        <Text color={statusColor as any}>{statusIcon}</Text>
        {message.duration && (
          <Text color="gray">({message.duration}ms)</Text>
        )}
      </Box>
    );
  }

  // Regular message
  return (
    <Box flexDirection="column">
      <Box flexDirection="row" gap={1}>
        <Text color={color} bold>
          {prefix}
        </Text>
        <Text>{displayContent}</Text>
      </Box>
    </Box>
  );
}
