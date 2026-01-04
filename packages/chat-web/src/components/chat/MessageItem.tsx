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

interface ToolDescription {
  /** The canonical tool name (shown in bold) */
  label: string;
  /** Additional details like filename, command, etc. */
  detail?: string;
}

/**
 * Format a structured tool description with separate label and detail
 * Label is shown bold, detail is shown in normal weight
 */
function formatToolDescription(toolName: string, toolInput?: string): ToolDescription {
  if (!toolInput) {
    return { label: formatToolLabel(toolName) };
  }

  try {
    const args = JSON.parse(toolInput);

    // Try to extract file path from various possible argument names
    const filePath = args.file_path || args.filePath || args.path || args.file;
    const getFilename = (p: string) => p.split('/').pop() || p;

    switch (toolName.toLowerCase()) {
      case 'read': {
        if (filePath) {
          return { label: 'Read', detail: getFilename(filePath) };
        }
        return { label: 'Read' };
      }

      case 'write': {
        if (filePath) {
          return { label: 'Write', detail: getFilename(filePath) };
        }
        return { label: 'Write' };
      }

      case 'edit': {
        if (filePath) {
          return { label: 'Edit', detail: getFilename(filePath) };
        }
        return { label: 'Edit' };
      }

      case 'bash': {
        const cmd = args.command || args.cmd;
        if (cmd) {
          const displayCmd = cmd.length > 60 ? cmd.substring(0, 60) + '…' : cmd;
          return { label: 'Bash', detail: displayCmd };
        }
        return { label: 'Bash' };
      }

      // Shell commands that should show as "Bash <command>"
      case 'ls': {
        const path = args.path || args.directory || args.dir || '.';
        return { label: 'Bash', detail: `ls ${path}` };
      }

      case 'cat': {
        if (filePath) {
          return { label: 'Bash', detail: `cat ${getFilename(filePath)}` };
        }
        return { label: 'Bash', detail: 'cat' };
      }

      case 'mkdir': {
        const dir = args.path || args.directory || args.name;
        if (dir) {
          return { label: 'Bash', detail: `mkdir ${dir}` };
        }
        return { label: 'Bash', detail: 'mkdir' };
      }

      case 'rm': {
        if (filePath) {
          return { label: 'Bash', detail: `rm ${getFilename(filePath)}` };
        }
        return { label: 'Bash', detail: 'rm' };
      }

      case 'mv': {
        const src = args.source || args.src || args.from;
        const dst = args.destination || args.dst || args.to;
        if (src && dst) {
          return { label: 'Bash', detail: `mv ${getFilename(src)} → ${getFilename(dst)}` };
        }
        return { label: 'Bash', detail: 'mv' };
      }

      case 'cp': {
        const src = args.source || args.src || args.from;
        const dst = args.destination || args.dst || args.to;
        if (src && dst) {
          return { label: 'Bash', detail: `cp ${getFilename(src)} → ${getFilename(dst)}` };
        }
        return { label: 'Bash', detail: 'cp' };
      }

      case 'glob': {
        const pattern = args.pattern;
        if (pattern) {
          return { label: 'Glob', detail: pattern };
        }
        return { label: 'Glob' };
      }

      case 'grep': {
        const pattern = args.pattern || args.query;
        const searchPath = args.path;
        if (pattern) {
          const shortPattern = pattern.length > 40 ? pattern.substring(0, 40) + '…' : pattern;
          const detail = searchPath ? `"${shortPattern}" in ${getFilename(searchPath)}` : `"${shortPattern}"`;
          return { label: 'Grep', detail };
        }
        return { label: 'Grep' };
      }

      case 'task': {
        const desc = args.description || args.prompt;
        if (desc) {
          const shortDesc = desc.length > 50 ? desc.substring(0, 50) + '…' : desc;
          return { label: 'Task', detail: shortDesc };
        }
        return { label: 'Task' };
      }

      case 'webfetch': {
        const url = args.url;
        if (url) {
          try {
            const domain = new URL(url).hostname;
            return { label: 'WebFetch', detail: domain };
          } catch {
            return { label: 'WebFetch', detail: url.substring(0, 40) };
          }
        }
        return { label: 'WebFetch' };
      }

      case 'websearch': {
        const query = args.query;
        if (query) {
          const shortQuery = query.length > 40 ? query.substring(0, 40) + '…' : query;
          return { label: 'WebSearch', detail: `"${shortQuery}"` };
        }
        return { label: 'WebSearch' };
      }

      case 'todowrite': {
        return { label: 'TodoWrite' };
      }

      case 'notebookedit': {
        const nbPath = args.notebook_path;
        if (nbPath) {
          return { label: 'NotebookEdit', detail: getFilename(nbPath) };
        }
        return { label: 'NotebookEdit' };
      }

      case 'askuserquestion': {
        return { label: 'AskUser' };
      }

      case 'enterplanmode': {
        return { label: 'PlanMode' };
      }

      case 'exitplanmode': {
        return { label: 'PlanMode', detail: 'exit' };
      }

      default:
        // Handle MCP tools and other unknown tools
        return { label: formatToolLabel(toolName) };
    }
  } catch {
    return { label: formatToolLabel(toolName) };
  }
}

/**
 * Format a tool name into a readable label
 */
function formatToolLabel(toolName: string): string {
  // Handle MCP tool names like "mcp__server__tool"
  if (toolName.startsWith('mcp__')) {
    const parts = toolName.split('__');
    // Return the last part as the tool name
    return parts[parts.length - 1] || toolName;
  }
  // Capitalize first letter
  return toolName.charAt(0).toUpperCase() + toolName.slice(1);
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
  const { label, detail } = formatToolDescription(toolName, toolInput);

  return (
    <div className="tool-header">
      <span className={`tool-status ${status}`}>{statusIcon}</span>
      <span className="tool-name">
        <strong className="tool-label">{label}</strong>
        {detail && <span className="tool-detail">{detail}</span>}
      </span>
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
