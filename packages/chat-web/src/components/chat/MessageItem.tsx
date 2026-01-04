/**
 * @fileoverview MessageItem Component
 *
 * Terminal-style message display with role prefix icons.
 * Supports user, assistant, system, and tool messages.
 */

import { useState, useCallback, useMemo } from 'react';
import type { DisplayMessage } from '../../store/types.js';
import { StreamingContent } from './StreamingContent.js';
import './MessageItem.css';

// =============================================================================
// Types
// =============================================================================

export interface MessageItemProps {
  /** The message to display */
  message: DisplayMessage;
  /** Whether this message is currently streaming */
  isStreaming?: boolean;
}

// =============================================================================
// Constants
// =============================================================================

const ROLE_PREFIXES = {
  user: '›',
  assistant: '✦',
  system: '⚡',
  tool: '◐',
} as const;

const TOOL_STATUS_ICONS = {
  running: '◐',
  success: '✓',
  error: '✗',
} as const;

const COLLAPSE_THRESHOLD = 500; // chars

// =============================================================================
// Helper Components
// =============================================================================

interface ToolHeaderProps {
  toolName: string;
  status: 'running' | 'success' | 'error';
  duration?: number;
}

function ToolHeader({ toolName, status, duration }: ToolHeaderProps) {
  const statusIcon = TOOL_STATUS_ICONS[status];
  const formattedDuration = duration ? `${(duration / 1000).toFixed(1)}s` : null;

  return (
    <div className="tool-header">
      <span className={`tool-status ${status}`}>{statusIcon}</span>
      <span className="tool-name">{toolName}</span>
      {formattedDuration && (
        <span className="tool-duration">{formattedDuration}</span>
      )}
    </div>
  );
}

// =============================================================================
// Component
// =============================================================================

export function MessageItem({ message, isStreaming = false }: MessageItemProps) {
  const [isExpanded, setIsExpanded] = useState(false);

  const handleToggle = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  // Determine if content is long and should be collapsible
  // Only collapse tool messages - assistant messages should always show in full
  const shouldCollapse = message.role === 'tool' && message.content.length > COLLAPSE_THRESHOLD;
  const isCollapsed = shouldCollapse && !isExpanded;

  // Get role-specific styling
  const roleClass = `role-${message.role}`;
  const prefix = ROLE_PREFIXES[message.role] || '?';

  // Format timestamp
  const formattedTime = useMemo(() => {
    const date = new Date(message.timestamp);
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }, [message.timestamp]);

  // Build classes
  const itemClasses = ['message-item', roleClass].join(' ');
  const contentClasses = [
    'message-content',
    shouldCollapse && 'collapsible',
    isCollapsed && 'collapsed',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <article
      className={itemClasses}
      role="article"
      aria-label={`${message.role} message`}
    >
      {/* Role prefix */}
      <span className={`message-prefix ${message.role}`}>{prefix}</span>

      {/* Message body */}
      <div className="message-body">
        {/* Tool header for tool messages */}
        {message.role === 'tool' && message.toolName && (
          <ToolHeader
            toolName={message.toolName}
            status={message.toolStatus || 'success'}
            duration={message.duration}
          />
        )}

        {/* Content */}
        <div className={contentClasses}>
          {message.role === 'assistant' ? (
            <StreamingContent
              content={message.content}
              isStreaming={isStreaming}
            />
          ) : (
            <pre className="message-text">
              {typeof message.content === 'string'
                ? message.content
                : JSON.stringify(message.content, null, 2)}
            </pre>
          )}
        </div>

        {/* Expand/collapse button for long content */}
        {shouldCollapse && (
          <button
            className="message-toggle"
            onClick={handleToggle}
            type="button"
            aria-expanded={isExpanded}
          >
            {isExpanded ? '▴ Show less' : '▾ Show more'}
          </button>
        )}

        {/* Timestamp */}
        <time className="message-time" dateTime={message.timestamp}>
          {formattedTime}
        </time>
      </div>
    </article>
  );
}
