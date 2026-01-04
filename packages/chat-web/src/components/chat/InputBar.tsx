/**
 * @fileoverview Chat input bar with send/stop functionality
 *
 * Features:
 * - Auto-resize textarea
 * - Shift+Enter for newlines
 * - Up/Down for history navigation
 * - Slash command detection
 * - Escape to interrupt or close menus
 */
import React, { useState, useRef, useEffect, useCallback, forwardRef } from 'react';
import { Spinner } from '../ui/Spinner.js';
import { useInputHistory } from '../../hooks/useInputHistory.js';
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
  /** Called when slash command detected */
  onSlashCommand?: (partialCommand: string) => void;
  /** Called on Escape key */
  onEscape?: () => void;
  /** Disable input */
  disabled?: boolean;
  /** Show processing state */
  isProcessing?: boolean;
  /** Placeholder text */
  placeholder?: string;
  /** Whether command palette is open */
  commandPaletteOpen?: boolean;
}

// =============================================================================
// Constants
// =============================================================================

const LINE_HEIGHT = 22;
const MAX_ROWS = 8;
const VERTICAL_PADDING = 14; // Total padding to match 36px button height

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
      onSlashCommand,
      onEscape,
      disabled = false,
      isProcessing = false,
      placeholder = 'Type a message... (/ for commands)',
      commandPaletteOpen = false,
    },
    ref,
  ) {
    // Internal state for uncontrolled mode
    const [internalValue, setInternalValue] = useState('');
    const [rows, setRows] = useState(1);
    const [isFocused, setIsFocused] = useState(false);

    // History navigation
    const {
      addToHistory,
      navigateUp,
      navigateDown,
      resetNavigation,
      isNavigating,
    } = useInputHistory();

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

    // Reset history navigation when value changes (unless navigating)
    useEffect(() => {
      if (!isNavigating) {
        resetNavigation();
      }
    }, [value, isNavigating, resetNavigation]);

    const setValue = useCallback(
      (newValue: string) => {
        if (isControlled) {
          controlledOnChange?.(newValue);
        } else {
          setInternalValue(newValue);
        }
      },
      [isControlled, controlledOnChange]
    );

    const handleChange = useCallback(
      (e: React.ChangeEvent<HTMLTextAreaElement>) => {
        const newValue = e.target.value;
        setValue(newValue);

        // Detect slash commands (when input starts with / and no spaces yet)
        if (newValue.startsWith('/') && !newValue.includes(' ')) {
          onSlashCommand?.(newValue);
        }
      },
      [setValue, onSlashCommand],
    );

    const handleSubmit = useCallback(() => {
      const trimmed = value.trim();
      if (trimmed && !disabled && !isProcessing) {
        // Add to history before submitting
        addToHistory(trimmed);
        onSubmit(trimmed);
        if (!isControlled) {
          setInternalValue('');
          setRows(1);
        }
      }
    }, [value, disabled, isProcessing, onSubmit, isControlled, addToHistory]);

    const handleKeyDown = useCallback(
      (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
        // Enter without shift = submit
        if (e.key === 'Enter' && !e.shiftKey) {
          // Don't submit if command palette is open
          if (commandPaletteOpen) {
            return;
          }
          e.preventDefault();
          handleSubmit();
          return;
        }

        // Escape - interrupt or close menu
        if (e.key === 'Escape') {
          e.preventDefault();
          onEscape?.();
          return;
        }

        // Up arrow - history navigation (only at start of input or empty)
        if (e.key === 'ArrowUp') {
          const textarea = e.currentTarget;
          const atStart = textarea.selectionStart === 0 && textarea.selectionEnd === 0;
          const isEmpty = !value.trim();

          if (atStart || isEmpty) {
            e.preventDefault();
            const historyValue = navigateUp(value);
            if (historyValue !== null) {
              setValue(historyValue);
            }
            return;
          }
        }

        // Down arrow - history navigation (only at end of input)
        if (e.key === 'ArrowDown') {
          const textarea = e.currentTarget;
          const atEnd = textarea.selectionStart === value.length && textarea.selectionEnd === value.length;

          if (atEnd) {
            e.preventDefault();
            const historyValue = navigateDown();
            if (historyValue !== null) {
              setValue(historyValue);
            }
            return;
          }
        }
      },
      [value, handleSubmit, onEscape, navigateUp, navigateDown, setValue, commandPaletteOpen],
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
            aria-label="Message input"
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
