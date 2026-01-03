/**
 * @fileoverview Message List Component
 *
 * Displays the conversation messages with streaming support.
 * Uses elegant Unicode icons and markdown rendering.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { ThinkingIndicator } from './ThinkingIndicator.js';
import { StreamingContent } from './StreamingContent.js';
import { ToolExecution } from './ToolExecution.js';
import { MarkdownText } from './MarkdownText.js';
import type { DisplayMessage } from '../types.js';
import { inkColors, icons } from '../theme.js';

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
  // Show "Ready" indicator when no messages and not processing
  const showReady = messages.length === 0 && !isProcessing && !streamingContent;

  return (
    <Box flexDirection="column" gap={1}>
      {showReady && (
        <Box flexDirection="row" gap={1} marginLeft={1}>
          <Text color={inkColors.statusReady}>{icons.ready}</Text>
          <Text color={inkColors.label}>Ready</Text>
        </Box>
      )}

      {messages.map((message) => (
        <MessageItem key={message.id} message={message} />
      ))}

      {/* Thinking indicator - pulsing bars */}
      {/* Aligned with text after prompt prefix (> ) - marginLeft=1 + 2 spaces for "> " */}
      {isProcessing && thinkingText && !streamingContent && (
        <Box flexDirection="column" marginLeft={1}>
          <Box flexDirection="row">
            <Text>  </Text>
            <ThinkingIndicator label="Thinking" color={inkColors.statusThinking} />
          </Box>
          {thinkingText.length > 0 && (
            <Box flexDirection="column" marginLeft={5}>
              {formatThinkingText(thinkingText).map((line, index) => (
                <Text key={index} color={inkColors.dim}>
                  {line}
                </Text>
              ))}
            </Box>
          )}
        </Box>
      )}

      {/* Show thinking indicator when processing but not yet streaming or thinking */}
      {/* Aligned with text after prompt prefix (> ) */}
      {isProcessing && !streamingContent && !thinkingText && !activeTool && (
        <Box marginLeft={1} flexDirection="row">
          <Text>  </Text>
          <ThinkingIndicator label="Thinking" color={inkColors.spinner} />
        </Box>
      )}

      {/* Tool execution indicator */}
      {activeTool && (
        <Box marginLeft={1}>
          <ToolExecution
            toolName={activeTool}
            status="running"
            toolInput={activeToolInput ?? undefined}
          />
        </Box>
      )}

      {/* Streaming content */}
      {streamingContent && (
        <Box flexDirection="row" marginLeft={1}>
          <Text color={inkColors.roleAssistant}>{icons.streaming} </Text>
          <Box flexShrink={1}>
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
        return { prefix: icons.user, color: inkColors.roleUser, content: message.content };
      case 'assistant':
        return { prefix: icons.assistant, color: inkColors.roleAssistant, content: message.content };
      case 'system': {
        // Check if message starts with an emoji icon (like ⏸) - use it as the prefix
        const iconMatch = message.content.match(/^([\u{1F300}-\u{1F9FF}]|[\u{2300}-\u{23FF}]|[\u{25A0}-\u{25FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|⏸)/u);
        if (iconMatch) {
          return {
            prefix: iconMatch[0],
            color: inkColors.roleSystem,
            content: message.content.slice(iconMatch[0].length).trimStart(),
          };
        }
        return { prefix: icons.system, color: inkColors.roleSystem, content: message.content };
      }
      case 'tool':
        return { prefix: icons.toolSuccess, color: inkColors.roleTool, content: message.content };
      default:
        return { prefix: '?', color: inkColors.value, content: message.content };
    }
  };

  const { prefix, color, content } = getRoleDisplay();

  // For tool messages, show tool name and status with output
  if (message.role === 'tool') {
    const status = message.toolStatus ?? 'success';
    return (
      <Box marginLeft={1}>
        <ToolExecution
          toolName={message.toolName ?? 'unknown'}
          status={status}
          toolInput={message.toolInput}
          duration={message.duration}
          output={message.content}
        />
      </Box>
    );
  }

  // User messages - simple display
  if (message.role === 'user') {
    return (
      <Box flexDirection="row" marginLeft={1}>
        <Text color={color}>{prefix} </Text>
        <Text wrap="wrap">{content}</Text>
      </Box>
    );
  }

  // System messages - simple display (content may have been modified to extract icon)
  if (message.role === 'system') {
    return (
      <Box flexDirection="row" marginLeft={1}>
        <Text color={color}>{prefix} </Text>
        <Text wrap="wrap">{content}</Text>
      </Box>
    );
  }

  // Assistant messages - render markdown with proper indentation
  // The icon is on its own, content starts on same line and wraps underneath
  return (
    <Box flexDirection="row" marginLeft={1}>
      <Text color={color}>{prefix} </Text>
      <Box flexDirection="column" flexShrink={1}>
        <MarkdownText content={content} />
      </Box>
    </Box>
  );
}

