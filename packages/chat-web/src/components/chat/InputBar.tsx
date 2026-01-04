/**
 * @fileoverview Chat input bar with send/stop functionality
 *
 * Supports both controlled and uncontrolled modes.
 */
import React, { useState, useRef, useEffect, useCallback, forwardRef } from 'react';
import { Spinner } from '../ui/Spinner.js';
import './InputBar.css';

// =============================================================================
// Types
// =============================================================================

interface InputBarProps {
  /** Controlled value */
  value?: string;
  /** Called when value changes (controlled mode) */
  onChange?: (value: string) => void;
  /** Called when user submits */
  onSubmit: (message: string) => void;
  /** Called when stop button clicked */
  onStop?: () => void;
  /** Disable input */
  disabled?: boolean;
  /** Show processing state */
  isProcessing?: boolean;
  /** Placeholder text */
  placeholder?: string;
}

// =============================================================================
// Constants
// =============================================================================

const LINE_HEIGHT = 22;
const MAX_ROWS = 8;
const VERTICAL_PADDING = 20;

// =============================================================================
// Component
// =============================================================================

export const InputBar = forwardRef<HTMLTextAreaElement, InputBarProps>(
  function InputBar(
    {
      value: controlledValue,
      onChange: controlledOnChange,
      onSubmit,
      onStop,
      disabled = false,
      isProcessing = false,
      placeholder = 'Type a message...',
    },
    ref,
  ) {
    // Internal state for uncontrolled mode
    const [internalValue, setInternalValue] = useState('');
    const [rows, setRows] = useState(1);
    const [isFocused, setIsFocused] = useState(false);

    // Use controlled or internal value
    const isControlled = controlledValue !== undefined;
    const value = isControlled ? controlledValue : internalValue;

    // Internal ref for when no external ref provided
    const internalRef = useRef<HTMLTextAreaElement>(null);
    const textareaRef = (ref as React.RefObject<HTMLTextAreaElement>) || internalRef;

    // Auto-resize textarea based on content
    useEffect(() => {
      const lineCount = (value.match(/\n/g) || []).length + 1;
      setRows(Math.min(lineCount, MAX_ROWS));
    }, [value]);

    const handleChange = useCallback(
      (e: React.ChangeEvent<HTMLTextAreaElement>) => {
        const newValue = e.target.value;
        if (isControlled) {
          controlledOnChange?.(newValue);
        } else {
          setInternalValue(newValue);
        }
      },
      [isControlled, controlledOnChange],
    );

    const handleSubmit = useCallback(() => {
      const trimmed = value.trim();
      if (trimmed && !disabled && !isProcessing) {
        onSubmit(trimmed);
        if (!isControlled) {
          setInternalValue('');
          setRows(1);
        }
      }
    }, [value, disabled, isProcessing, onSubmit, isControlled]);

    const handleKeyDown = useCallback(
      (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          handleSubmit();
        }
      },
      [handleSubmit],
    );

    const showStopButton = isProcessing && !value.trim();

    return (
      <div className="input-bar">
        {/* Text input wrapper */}
        <div className={`input-bar-wrapper ${isFocused ? 'focused' : ''}`}>
          <textarea
            ref={textareaRef}
            value={value}
            onChange={handleChange}
            onKeyDown={handleKeyDown}
            onFocus={() => setIsFocused(true)}
            onBlur={() => setIsFocused(false)}
            disabled={disabled}
            placeholder={placeholder}
            rows={rows}
            className="input-bar-textarea"
            style={{
              height: `${rows * LINE_HEIGHT + VERTICAL_PADDING}px`,
            }}
          />
        </div>

        {/* Send/Stop button */}
        <button
          onClick={showStopButton ? onStop : handleSubmit}
          disabled={!showStopButton && (!value.trim() || disabled)}
          className={`input-bar-button ${showStopButton ? 'stop' : 'send'}`}
          type="button"
          aria-label={showStopButton ? 'Stop' : 'Send'}
        >
          {showStopButton ? (
            <svg width={16} height={16} viewBox="0 0 16 16" fill="currentColor">
              <rect x="3" y="3" width="10" height="10" rx="1" />
            </svg>
          ) : isProcessing ? (
            <Spinner size={18} />
          ) : (
            <svg
              width={18}
              height={18}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth={2.5}
            >
              <path
                d="M12 19V5M5 12l7-7 7 7"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          )}
        </button>
      </div>
    );
  },
);
