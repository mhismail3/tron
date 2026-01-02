/**
 * @fileoverview Message List Component
 *
 * Displays the conversation messages with streaming support.
 * NO emojis - uses ASCII/Unicode characters only.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { Spinner } from './Spinner.js';
import { StreamingContent } from './StreamingContent.js';
import { ToolExecution } from './ToolExecution.js';
import type { DisplayMessage } from '../types.js';

// Thinking display configuration
const MAX_THINKING_LINES = 4;
const MAX_THINKING_LINE_LENGTH = 80;

/**
 * Format thinking text for multi-line truncated display
 */
function formatThinkingText(text: string): string[] {
  if (!text || text.trim().length === 0) return [];

  // Split by newlines or sentences
  const lines = text.split(/\n/).filter(l => l.trim());

  // If no natural line breaks, create lines by wrapping
  if (lines.length === 1 && text.length > MAX_THINKING_LINE_LENGTH) {
    const words = text.split(' ');
    const wrapped: string[] = [];
    let currentLine = '';

    for (const word of words) {
      if ((currentLine + ' ' + word).length > MAX_THINKING_LINE_LENGTH) {
        if (currentLine) wrapped.push(currentLine);
        currentLine = word;
      } else {
        currentLine = currentLine ? currentLine + ' ' + word : word;
      }
      if (wrapped.length >= MAX_THINKING_LINES) break;
    }
    if (currentLine && wrapped.length < MAX_THINKING_LINES) {
      wrapped.push(currentLine);
    }
    if (words.length > wrapped.join(' ').split(' ').length) {
      wrapped.push('...');
    }
    return wrapped;
  }

  // Truncate each line and limit number of lines
  const truncatedLines = lines.slice(0, MAX_THINKING_LINES).map(line => {
    if (line.length > MAX_THINKING_LINE_LENGTH) {
      return line.slice(0, MAX_THINKING_LINE_LENGTH - 3) + '...';
    }
    return line;
  });

  if (lines.length > MAX_THINKING_LINES) {
    truncatedLines.push('...');
  }

  return truncatedLines;
}

export interface MessageListProps {
  messages: DisplayMessage[];
  isProcessing: boolean;
  activeTool: string | null;
  /** Active tool input/command being executed */
  activeToolInput?: string | null;
  /** Content currently being streamed */
  streamingContent?: string;
  /** Whether text is actively streaming */
  isStreaming?: boolean;
  /** Current thinking text */
  thinkingText?: string;
}

export function MessageList({
  messages,
  isProcessing,
  activeTool,
  activeToolInput,
  streamingContent,
  isStreaming,
  thinkingText,
}: MessageListProps): React.ReactElement {
  return (
    <Box flexDirection="column" gap={1}>
      {messages.map((message) => (
        <MessageItem key={message.id} message={message} />
      ))}

      {/* Thinking indicator - only show when thinking and no streaming yet */}
      {isProcessing && thinkingText && !streamingContent && (
        <Box flexDirection="column">
          <Spinner label="Thinking" color="cyan" />
          {thinkingText.length > 0 && (
            <Box flexDirection="column" marginLeft={2}>
              {formatThinkingText(thinkingText).map((line, index) => (
                <Text key={index} color="gray" dimColor>
                  {line}
                </Text>
              ))}
            </Box>
          )}
        </Box>
      )}

      {/* Show spinner when processing but not yet streaming or thinking */}
      {isProcessing && !streamingContent && !thinkingText && !activeTool && (
        <Spinner label="Thinking" color="yellow" />
      )}

      {/* Tool execution indicator */}
      {activeTool && (
        <ToolExecution
          toolName={activeTool}
          status="running"
          toolInput={activeToolInput ?? undefined}
        />
      )}

      {/* Streaming content */}
      {streamingContent && (
        <Box flexDirection="column">
          <Box flexDirection="row" gap={1}>
            <Text color="green" bold>*</Text>
            <StreamingContent
              content={streamingContent}
              isStreaming={isStreaming ?? false}
            />
          </Box>
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
        return { prefix: '>', color: 'cyan' as const };
      case 'assistant':
        return { prefix: '*', color: 'green' as const };
      case 'system':
        return { prefix: '-', color: 'gray' as const };
      case 'tool':
        return { prefix: '+', color: 'yellow' as const };
      default:
        return { prefix: '?', color: 'white' as const };
    }
  };

  const { prefix, color } = getRoleDisplay();

  // For tool messages, show tool name and status with output
  if (message.role === 'tool') {
    const status = message.toolStatus ?? 'success';
    return (
      <ToolExecution
        toolName={message.toolName ?? 'unknown'}
        status={status}
        toolInput={message.toolInput}
        duration={message.duration}
        output={message.content}
      />
    );
  }

  // Regular message - show full content (no truncation for better readability)
  return (
    <Box flexDirection="column">
      <Box flexDirection="row" gap={1}>
        <Text color={color} bold>
          {prefix}
        </Text>
        <Text wrap="wrap">{message.content}</Text>
      </Box>
    </Box>
  );
}

