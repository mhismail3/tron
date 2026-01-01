/**
 * @fileoverview Chat input bar with send/stop functionality
 */
import React, { useState, useRef, useEffect, useCallback } from 'react';
import { Spinner } from '../ui/Spinner.js';

interface InputBarProps {
  onSubmit: (message: string) => void;
  onStop?: () => void;
  disabled?: boolean;
  isProcessing?: boolean;
  placeholder?: string;
}

const LINE_HEIGHT = 22;
const MAX_ROWS = 8;
const VERTICAL_PADDING = 20;

export function InputBar({
  onSubmit,
  onStop,
  disabled = false,
  isProcessing = false,
  placeholder = 'Type a message...',
}: InputBarProps): React.ReactElement {
  const [message, setMessage] = useState('');
  const [rows, setRows] = useState(1);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [isFocused, setIsFocused] = useState(false);

  // Auto-resize textarea
  useEffect(() => {
    if (textareaRef.current) {
      const lineCount = (message.match(/\n/g) || []).length + 1;
      setRows(Math.min(lineCount, MAX_ROWS));
    }
  }, [message]);

  const handleSubmit = useCallback(() => {
    const trimmed = message.trim();
    if (trimmed && !disabled && !isProcessing) {
      onSubmit(trimmed);
      setMessage('');
      setRows(1);
    }
  }, [message, disabled, isProcessing, onSubmit]);

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const showStopButton = isProcessing && !message.trim();

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'flex-end',
        gap: 'var(--space-sm)',
        padding: 'var(--space-md)',
        background: 'var(--bg-surface)',
        borderTop: '1px solid var(--border-subtle)',
      }}
    >
      {/* Text input */}
      <div
        style={{
          flex: 1,
          display: 'flex',
          alignItems: 'center',
          background: 'var(--bg-elevated)',
          borderRadius: 'var(--radius-lg)',
          border: `1px solid ${isFocused ? 'var(--accent)' : 'var(--border-default)'}`,
          boxShadow: isFocused ? '0 0 0 2px var(--accent-muted)' : 'none',
          transition: 'border-color var(--transition-fast), box-shadow var(--transition-fast)',
        }}
      >
        <textarea
          ref={textareaRef}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          onKeyDown={handleKeyDown}
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          disabled={disabled}
          placeholder={placeholder}
          rows={rows}
          style={{
            flex: 1,
            height: `${rows * LINE_HEIGHT + VERTICAL_PADDING}px`,
            padding: 'var(--space-md)',
            background: 'transparent',
            border: 'none',
            outline: 'none',
            resize: 'none',
            color: 'var(--text-primary)',
            fontFamily: 'var(--font-sans)',
            fontSize: 'var(--text-base)',
            lineHeight: `${LINE_HEIGHT}px`,
            opacity: disabled ? 0.5 : 1,
          }}
        />
      </div>

      {/* Send/Stop button */}
      <button
        onClick={showStopButton ? onStop : handleSubmit}
        disabled={!showStopButton && (!message.trim() || disabled)}
        style={{
          width: 44,
          height: 44,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: showStopButton ? 'var(--error)' : 'var(--accent)',
          color: 'var(--text-primary)',
          border: 'none',
          borderRadius: 'var(--radius-md)',
          cursor: 'pointer',
          opacity: !showStopButton && (!message.trim() || disabled) ? 0.5 : 1,
          transition: 'opacity var(--transition-fast), transform var(--transition-fast)',
          boxShadow: 'var(--shadow-sm)',
        }}
        onMouseDown={(e) => {
          (e.target as HTMLButtonElement).style.transform = 'scale(0.9)';
        }}
        onMouseUp={(e) => {
          (e.target as HTMLButtonElement).style.transform = 'scale(1)';
        }}
        onMouseLeave={(e) => {
          (e.target as HTMLButtonElement).style.transform = 'scale(1)';
        }}
      >
        {showStopButton ? (
          // Stop icon (square)
          <svg width={16} height={16} viewBox="0 0 16 16" fill="currentColor">
            <rect x="3" y="3" width="10" height="10" rx="1" />
          </svg>
        ) : isProcessing ? (
          <Spinner size={18} />
        ) : (
          // Send icon (arrow up)
          <svg width={18} height={18} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.5}>
            <path d="M12 19V5M5 12l7-7 7 7" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        )}
      </button>
    </div>
  );
}
