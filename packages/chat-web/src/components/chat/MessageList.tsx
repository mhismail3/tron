/**
 * @fileoverview MessageList Component
 *
 * Displays the conversation messages with streaming, thinking, and tool indicators.
 * Terminal-style layout matching the TUI design.
 */

import { useEffect, useRef } from 'react';
import type { DisplayMessage } from '../../store/types.js';
import { MessageItem } from './MessageItem.js';
import { ThinkingBlock } from './ThinkingBlock.js';
import { StreamingContent } from './StreamingContent.js';
import { WelcomeBox } from './WelcomeBox.js';
import { ToolIndicator } from './ToolIndicator.js';
import './MessageList.css';

// =============================================================================
// Types
// =============================================================================

export interface MessageListProps {
  /** Messages to display */
  messages: DisplayMessage[];
  /** Whether the agent is processing */
  isProcessing?: boolean;
  /** Active tool name */
  activeTool?: string | null;
  /** Active tool input/command */
  activeToolInput?: string | null;
  /** Content currently being streamed */
  streamingContent?: string;
  /** Whether text is actively streaming */
  isStreaming?: boolean;
  /** Current thinking text */
  thinkingText?: string;
  /** Welcome box model */
  welcomeModel?: string;
  /** Welcome box working directory */
  welcomeWorkingDirectory?: string;
  /** Welcome box git branch */
  welcomeGitBranch?: string;
  /** Whether to show welcome */
  showWelcome?: boolean;
}

// =============================================================================
// Component
// =============================================================================

export function MessageList({
  messages,
  isProcessing = false,
  activeTool,
  activeToolInput,
  streamingContent,
  isStreaming = false,
  thinkingText,
  welcomeModel,
  welcomeWorkingDirectory,
  welcomeGitBranch,
  showWelcome = false,
}: MessageListProps) {
  const listRef = useRef<HTMLDivElement>(null);
  const endRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new content arrives
  useEffect(() => {
    if (endRef.current && typeof endRef.current.scrollIntoView === 'function') {
      endRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [messages, streamingContent, thinkingText, activeTool]);

  // Determine what to show in the dynamic area
  const showThinking =
    isProcessing && !streamingContent && !activeTool;
  const showActiveTool = isProcessing && activeTool && !streamingContent;
  const showStreaming = streamingContent && streamingContent.length > 0;
  const showEmpty = messages.length === 0 && !showWelcome;

  return (
    <div
      className="message-list scrollable"
      role="log"
      aria-live="polite"
      aria-label="Conversation messages"
      ref={listRef}
    >
      {/* Welcome Box */}
      {showWelcome && welcomeModel && welcomeWorkingDirectory && (
        <WelcomeBox
          model={welcomeModel}
          workingDirectory={welcomeWorkingDirectory}
          gitBranch={welcomeGitBranch}
        />
      )}

      {/* Empty State */}
      {showEmpty && (
        <div className="message-list-empty">
          <span className="empty-icon">◌</span>
          <span className="empty-text">No messages yet</span>
        </div>
      )}

      {/* Messages */}
      <div className="message-list-items">
        {messages.map((message) => (
          <MessageItem key={message.id} message={message} />
        ))}
      </div>

      {/* Dynamic Area - Live updates */}
      <div className="message-list-live">
        {/* Thinking Indicator */}
        {showThinking && (
          <ThinkingBlock label="Thinking" thinkingText={thinkingText} />
        )}

        {/* Active Tool */}
        {showActiveTool && (
          <ToolIndicator toolName={activeTool} toolInput={activeToolInput} />
        )}

        {/* Streaming Content */}
        {showStreaming && (
          <div className="streaming-area">
            <span className="streaming-prefix">▸</span>
            <StreamingContent
              content={streamingContent}
              isStreaming={isStreaming}
            />
          </div>
        )}
      </div>

      {/* Scroll anchor */}
      <div ref={endRef} className="scroll-anchor" />
    </div>
  );
}
