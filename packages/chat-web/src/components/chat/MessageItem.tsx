/**
 * @fileoverview MessageItem Component
 *
 * Terminal-style message display with role prefix icons.
 * Supports user, assistant, system, and tool messages.
 */

import { useState, useCallback, useMemo } from 'react';
import type { DisplayMessage } from '../../store/types.js';
import { StreamingContent } from './StreamingContent.js';
import { ToolResultViewer } from './ToolResultViewer.js';
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

const TOOL_STATUS_ICONS = {
  running: '↻',
  success: '✓',
  error: '✗',
} as const;

const COLLAPSE_THRESHOLD = 500; // chars

// =============================================================================
// Helpers
// =============================================================================

/**
 * Format a descriptive tool name from tool name + input
 */
function formatToolDescription(toolName: string, toolInput?: string): string {
  if (!toolInput) return toolName;

  try {
    const args = JSON.parse(toolInput);

    switch (toolName.toLowerCase()) {
      case 'read': {
        const path = args.file_path || args.path;
        if (path) {
          // Show just filename or last path segment
          const filename = path.split('/').pop() || path;
          return `Read ${filename}`;
        }
        return 'Read file';
      }

      case 'write': {
        const path = args.file_path || args.path;
        if (path) {
          const filename = path.split('/').pop() || path;
          return `Write ${filename}`;
        }
        return 'Write file';
      }

      case 'edit': {
        const path = args.file_path || args.path;
        if (path) {
          const filename = path.split('/').pop() || path;
          return `Edit ${filename}`;
        }
        return 'Edit file';
      }

      case 'bash': {
        const cmd = args.command;
        if (cmd) {
          // Show first part of command, truncated
          const shortCmd = cmd.length > 40 ? cmd.substring(0, 40) + '…' : cmd;
          return `$ ${shortCmd}`;
        }
        return 'Bash command';
      }

      case 'ls': {
        const path = args.path || args.directory || '.';
        return `ls ${path}`;
      }

      case 'grep': {
        const pattern = args.pattern || args.query;
        if (pattern) {
          const shortPattern = pattern.length > 30 ? pattern.substring(0, 30) + '…' : pattern;
          return `Grep "${shortPattern}"`;
        }
        return 'Search files';
      }

      case 'find': {
        const pattern = args.pattern || args.name;
        if (pattern) {
          return `Find ${pattern}`;
        }
        return 'Find files';
      }

      default:
        return toolName;
    }
  } catch {
    return toolName;
  }
}

/**
 * Format duration in a readable way
 */
function formatDuration(durationMs?: number): string | null {
  if (durationMs === undefined || durationMs === null) return null;
  if (durationMs < 1000) {
    return `Ran in ${Math.round(durationMs)}ms`;
  }
  return `Ran in ${(durationMs / 1000).toFixed(1)}s`;
}


// =============================================================================
// Helper Components
// =============================================================================

interface ToolHeaderProps {
  toolName: string;
  toolInput?: string;
  status: 'running' | 'success' | 'error';
  duration?: number;
}

function ToolHeader({ toolName, toolInput, status }: ToolHeaderProps) {
  const statusIcon = TOOL_STATUS_ICONS[status];
  const description = formatToolDescription(toolName, toolInput);

  return (
    <div className="tool-header">
      <span className={`tool-status ${status}`}>{statusIcon}</span>
      <span className="tool-name">{description}</span>
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

  // Format duration for tool messages
  const formattedDuration = message.role === 'tool' ? formatDuration(message.duration) : null;

  return (
    <article
      className={itemClasses}
      role="article"
      aria-label={`${message.role} message`}
    >
      {/* Message body */}
      <div className="message-body">
        {/* Tool header for tool messages */}
        {message.role === 'tool' && message.toolName && (
          <ToolHeader
            toolName={message.toolName}
            toolInput={message.toolInput}
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
          ) : message.role === 'tool' && message.toolName ? (
            <ToolResultViewer
              toolName={message.toolName}
              toolInput={message.toolInput}
              content={message.content}
              status={message.toolStatus || 'success'}
              isCollapsed={isCollapsed}
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

        {/* Timestamp and duration */}
        <div className="message-meta">
          <time className="message-time" dateTime={message.timestamp}>
            {formattedTime}
          </time>
          {formattedDuration && (
            <>
              <span className="meta-separator">·</span>
              <span className="message-duration">{formattedDuration}</span>
            </>
          )}
        </div>
      </div>
    </article>
  );
}
