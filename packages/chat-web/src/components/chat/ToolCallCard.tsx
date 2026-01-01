/**
 * @fileoverview Tool call card component with expandable details
 */
import React, { useState } from 'react';
import { Badge } from '../ui/Badge.js';
import { Spinner } from '../ui/Spinner.js';

export interface ToolCall {
  id: string;
  name: string;
  status: 'running' | 'success' | 'error';
  input?: string;
  output?: string;
  duration?: number;
}

interface ToolCallCardProps {
  tool: ToolCall;
}

// Tool-specific accent colors
const toolColors: Record<string, string> = {
  bash: '#4ade80',
  read: '#60a5fa',
  write: '#fbbf24',
  edit: '#c084fc',
  default: 'var(--accent)',
};

function getToolColor(name: string): string {
  const lowerName = name.toLowerCase();
  return toolColors[lowerName] || toolColors.default;
}

function getToolIcon(name: string): string {
  const icons: Record<string, string> = {
    bash: '$',
    read: '>',
    write: '+',
    edit: '~',
  };
  return icons[name.toLowerCase()] || '*';
}

export function ToolCallCard({ tool }: ToolCallCardProps): React.ReactElement {
  const [isExpanded, setIsExpanded] = useState(false);
  const color = getToolColor(tool.name);

  return (
    <div
      style={{
        background: 'var(--bg-surface)',
        borderRadius: 'var(--radius-md)',
        border: '1px solid var(--border-subtle)',
        borderLeft: `3px solid ${color}`,
        overflow: 'hidden',
      }}
    >
      {/* Header */}
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-sm)',
          width: '100%',
          padding: 'var(--space-sm) var(--space-md)',
          background: 'transparent',
          border: 'none',
          cursor: 'pointer',
          color: 'var(--text-primary)',
          textAlign: 'left',
        }}
      >
        {/* Status indicator */}
        {tool.status === 'running' ? (
          <Spinner size={14} color={color} />
        ) : (
          <span
            style={{
              fontFamily: 'var(--font-mono)',
              fontWeight: 600,
              color: tool.status === 'error' ? 'var(--error)' : color,
            }}
          >
            {tool.status === 'error' ? '!' : getToolIcon(tool.name)}
          </span>
        )}

        {/* Tool name */}
        <span
          style={{
            fontFamily: 'var(--font-mono)',
            fontWeight: 500,
            color: 'var(--text-primary)',
          }}
        >
          {tool.name}
        </span>

        {/* Tool input preview */}
        {tool.input && (
          <span
            style={{
              flex: 1,
              fontFamily: 'var(--font-mono)',
              fontSize: 'var(--text-sm)',
              color: 'var(--text-tertiary)',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
          >
            {tool.input.length > 50 ? tool.input.slice(0, 50) + '...' : tool.input}
          </span>
        )}

        {/* Duration */}
        {tool.duration !== undefined && (
          <Badge variant={tool.status === 'error' ? 'error' : 'default'}>
            {tool.duration}ms
          </Badge>
        )}

        {/* Expand indicator */}
        <span
          style={{
            color: 'var(--text-muted)',
            transform: isExpanded ? 'rotate(180deg)' : 'rotate(0deg)',
            transition: 'transform var(--transition-fast)',
          }}
        >
          v
        </span>
      </button>

      {/* Expandable content */}
      {isExpanded && (tool.input || tool.output) && (
        <div
          style={{
            padding: 'var(--space-md)',
            paddingTop: 0,
            display: 'flex',
            flexDirection: 'column',
            gap: 'var(--space-sm)',
          }}
        >
          {tool.input && (
            <div>
              <span
                style={{
                  fontSize: 'var(--text-xs)',
                  color: 'var(--text-muted)',
                  fontFamily: 'var(--font-mono)',
                }}
              >
                INPUT:
              </span>
              <pre
                style={{
                  marginTop: '4px',
                  padding: 'var(--space-sm)',
                  background: 'var(--bg-base)',
                  borderRadius: 'var(--radius-sm)',
                  fontSize: 'var(--text-sm)',
                  fontFamily: 'var(--font-mono)',
                  color: 'var(--text-secondary)',
                  overflow: 'auto',
                  maxHeight: '150px',
                }}
              >
                {tool.input}
              </pre>
            </div>
          )}

          {tool.output && (
            <div>
              <span
                style={{
                  fontSize: 'var(--text-xs)',
                  color: 'var(--text-muted)',
                  fontFamily: 'var(--font-mono)',
                }}
              >
                OUTPUT:
              </span>
              <pre
                style={{
                  marginTop: '4px',
                  padding: 'var(--space-sm)',
                  background: 'var(--bg-base)',
                  borderRadius: 'var(--radius-sm)',
                  fontSize: 'var(--text-sm)',
                  fontFamily: 'var(--font-mono)',
                  color: 'var(--text-secondary)',
                  overflow: 'auto',
                  maxHeight: '200px',
                }}
              >
                {tool.output}
              </pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
