/**
 * @fileoverview Message List Component
 *
 * Displays the conversation messages with streaming support.
 * Uses elegant Unicode icons and markdown rendering.
 *
 * CRITICAL FOR SCROLL BEHAVIOR:
 * Uses Ink's Static component for past messages. Static content is written
 * once and becomes part of the terminal's scrollback buffer - it's never
 * re-rendered. This allows users to scroll up freely while the agent processes.
 *
 * Only the "live" area (thinking indicator, streaming) is in the dynamic
 * render portion that gets re-rendered on state changes.
 *
 * The welcome box and messages are combined into a single Static flow to
 * ensure correct ordering (welcome first, then messages).
 */
import React from 'react';
import { Box, Text, Static } from 'ink';
import { ThinkingIndicator } from './ThinkingIndicator.js';
import { StreamingContent } from './StreamingContent.js';
import { ToolExecution } from './ToolExecution.js';
import { MarkdownText } from './MarkdownText.js';
import { WelcomeBox } from './WelcomeBox.js';
import type { DisplayMessage } from '../types.js';
import { inkColors, icons } from '../theme.js';

// Type for Static items - either welcome or message
type StaticItem =
  | { type: 'welcome'; id: string; model: string; workingDirectory: string; gitBranch?: string }
  | { type: 'message'; message: DisplayMessage };

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
  /** Welcome box props - rendered as first item in Static */
  welcomeModel?: string;
  welcomeWorkingDirectory?: string;
  welcomeGitBranch?: string;
  /** Whether to show welcome (controlled by parent to trigger Static render) */
  showWelcome?: boolean;
}

export function MessageList({
  messages,
  isProcessing,
  activeTool,
  activeToolInput,
  streamingContent,
  isStreaming,
  thinkingText,
  welcomeModel,
  welcomeWorkingDirectory,
  welcomeGitBranch,
  showWelcome = false,
}: MessageListProps): React.ReactElement {
  // Show "Ready" indicator when no messages and not processing and welcome shown
  const showReady = messages.length === 0 && !isProcessing && !streamingContent && showWelcome;

  // Build combined static items: welcome (if shown) + messages
  // This ensures welcome and messages are in the same Static flow with correct ordering
  const staticItems: StaticItem[] = React.useMemo(() => {
    const items: StaticItem[] = [];

    // Add welcome as first item if shown
    if (showWelcome && welcomeModel && welcomeWorkingDirectory) {
      items.push({
        type: 'welcome',
        id: 'welcome',
        model: welcomeModel,
        workingDirectory: welcomeWorkingDirectory,
        gitBranch: welcomeGitBranch,
      });
    }

    // Add all messages
    for (const message of messages) {
      items.push({ type: 'message', message });
    }

    return items;
  }, [showWelcome, welcomeModel, welcomeWorkingDirectory, welcomeGitBranch, messages]);

  return (
    <Box flexDirection="column" gap={1}>
      {showReady && (
        <Box flexDirection="row" gap={1} marginLeft={1}>
          <Text color={inkColors.statusReady}>{icons.ready}</Text>
          <Text color={inkColors.label}>Ready</Text>
        </Box>
      )}

      {/*
        STATIC CONTENT - Critical for scroll behavior!

        Static component renders items ONCE and never re-renders them.
        They become part of the terminal's scrollback buffer, allowing
        users to scroll up freely while the agent continues processing.

        Welcome box and messages are combined in one Static to ensure
        correct ordering (welcome first, then messages in order).
      */}
      <Static items={staticItems}>
        {(item, index) => {
          if (item.type === 'welcome') {
            return (
              <Box key={item.id} width="100%">
                <WelcomeBox
                  model={item.model}
                  workingDirectory={item.workingDirectory}
                  gitBranch={item.gitBranch}
                />
              </Box>
            );
          }
          // Message item
          return (
            <Box key={item.message.id} marginTop={index > 0 ? 1 : 0}>
              <MessageItem message={item.message} />
            </Box>
          );
        }}
      </Static>

      {/*
        DYNAMIC AREA - This is the only part that re-renders.

        Everything below here is the "live" area that updates during
        agent processing. It's kept minimal to reduce visual disruption.
      */}

      {/* Thinking indicator - pulsing bars */}
      {/* marginTop=1 provides spacing between static messages and dynamic thinking area */}
      {/* marginLeft=3 aligns bars with text content (1 base + 2 for "› " prefix) */}
      {isProcessing && thinkingText && !streamingContent && (
        <Box flexDirection="column" marginLeft={3} marginTop={1}>
          <Box flexDirection="row">
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
      {/* marginTop=1 provides spacing between static messages and dynamic thinking area */}
      {/* marginLeft=3 aligns bars with text content (1 base + 2 for "› " prefix) */}
      {isProcessing && !streamingContent && !thinkingText && !activeTool && (
        <Box marginLeft={3} marginTop={1} flexDirection="row">
          <ThinkingIndicator label="Thinking" color={inkColors.spinner} />
        </Box>
      )}

      {/* Tool execution indicator */}
      {/* marginTop=1 provides spacing between static messages and dynamic tool area */}
      {activeTool && (
        <Box marginLeft={1} marginTop={1}>
          <ToolExecution
            toolName={activeTool}
            status="running"
            toolInput={activeToolInput ?? undefined}
          />
        </Box>
      )}

      {/* Streaming content */}
      {/* marginTop=1 provides spacing between static messages and streaming area */}
      {streamingContent && (
        <Box flexDirection="row" marginLeft={1} marginTop={1}>
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
          tokenUsage={message.tokenUsage}
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
        <Box flexDirection="column" flexShrink={1}>
          <MarkdownText content={content} />
        </Box>
      </Box>
    );
  }

  // Assistant messages - render markdown with proper indentation
  // No token display here - tokens are shown only on tool operations
  return (
    <Box flexDirection="column" marginLeft={1}>
      <Box flexDirection="row">
        <Text color={color}>{prefix} </Text>
        <Box flexDirection="column" flexShrink={1}>
          <MarkdownText content={content} />
        </Box>
      </Box>
    </Box>
  );
}
