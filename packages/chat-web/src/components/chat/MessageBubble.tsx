/**
 * @fileoverview Message bubble component with support for different roles and tool calls
 */
import React from 'react';
import { ToolCallCard, type ToolCall } from './ToolCallCard.js';
import { Spinner } from '../ui/Spinner.js';

export interface Message {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: string;
  toolCalls?: ToolCall[];
  isStreaming?: boolean;
}

interface MessageBubbleProps {
  message: Message;
}

export function MessageBubble({ message }: MessageBubbleProps): React.ReactElement {
  const isUser = message.role === 'user';
  const isSystem = message.role === 'system';

  // User message styling
  if (isUser) {
    return (
      <div
        style={{
          display: 'flex',
          justifyContent: 'flex-end',
          marginBottom: 'var(--space-md)',
        }}
      >
        <div
          style={{
            maxWidth: '80%',
            padding: 'var(--space-md)',
            background: 'var(--user-bg)',
            color: 'var(--user-text)',
            borderRadius: 'var(--radius-lg)',
            borderBottomRightRadius: 'var(--radius-sm)',
            boxShadow: 'var(--shadow-sm)',
          }}
        >
          <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{message.content}</p>
        </div>
      </div>
    );
  }

  // System message styling
  if (isSystem) {
    return (
      <div
        style={{
          display: 'flex',
          justifyContent: 'center',
          marginBottom: 'var(--space-md)',
        }}
      >
        <div
          style={{
            padding: 'var(--space-sm) var(--space-md)',
            background: 'var(--bg-overlay)',
            color: 'var(--text-tertiary)',
            borderRadius: 'var(--radius-full)',
            fontSize: 'var(--text-sm)',
            fontFamily: 'var(--font-mono)',
          }}
        >
          {message.content}
        </div>
      </div>
    );
  }

  // Assistant message styling
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'flex-start',
        marginBottom: 'var(--space-md)',
      }}
    >
      <div
        style={{
          maxWidth: '85%',
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--space-sm)',
        }}
      >
        {/* Role indicator */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 'var(--space-xs)',
            marginLeft: 'var(--space-sm)',
          }}
        >
          <span
            style={{
              color: 'var(--accent)',
              fontWeight: 600,
              fontFamily: 'var(--font-mono)',
            }}
          >
            *
          </span>
          <span
            style={{
              fontSize: 'var(--text-xs)',
              color: 'var(--text-muted)',
              fontFamily: 'var(--font-mono)',
            }}
          >
            assistant
          </span>
          {message.isStreaming && (
            <Spinner size={12} color="var(--accent)" />
          )}
        </div>

        {/* Message content */}
        {message.content && (
          <div
            style={{
              padding: 'var(--space-md)',
              background: 'var(--bg-elevated)',
              borderRadius: 'var(--radius-lg)',
              borderBottomLeftRadius: 'var(--radius-sm)',
              border: '1px solid var(--border-subtle)',
            }}
          >
            <div
              style={{
                whiteSpace: 'pre-wrap',
                lineHeight: 1.6,
              }}
            >
              {message.content}
              {message.isStreaming && (
                <span
                  style={{
                    display: 'inline-block',
                    width: '8px',
                    height: '16px',
                    background: 'var(--accent)',
                    marginLeft: '2px',
                    animation: 'blink 1s infinite',
                  }}
                />
              )}
            </div>
          </div>
        )}

        {/* Tool calls */}
        {message.toolCalls && message.toolCalls.length > 0 && (
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 'var(--space-xs)',
            }}
          >
            {message.toolCalls.map((tool) => (
              <ToolCallCard key={tool.id} tool={tool} />
            ))}
          </div>
        )}
      </div>

      <style>
        {`
          @keyframes blink {
            0%, 50% { opacity: 1; }
            51%, 100% { opacity: 0; }
          }
        `}
      </style>
    </div>
  );
}
