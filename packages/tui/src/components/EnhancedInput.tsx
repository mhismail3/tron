/**
 * @fileoverview Enhanced Input Component
 *
 * Custom input component with advanced editing support:
 * - Ctrl+W: Delete word before cursor
 * - Ctrl+U: Delete to start of line
 * - Ctrl+K: Delete to end of line
 * - Delete key: Forward delete
 * - Ctrl+A: Move to start of line
 * - Ctrl+E: Move to end of line
 * - Cmd+Left/Right: Line start/end navigation (Mac)
 * - Shift+Enter: Insert newline (multiline mode)
 *
 * Note: Option/Alt key combinations aren't reliably detected by ink,
 * so we use Ctrl shortcuts instead (standard Unix/Emacs bindings).
 */
import React, { useRef, useEffect, useCallback } from 'react';
import { Box, Text, useInput, useFocus } from 'ink';
import { MultilineInput } from '../input/multiline-input.js';

export interface EnhancedInputProps {
  /** Current value */
  value: string;
  /** Called when value changes */
  onChange: (value: string) => void;
  /** Called when Enter is pressed (submit) */
  onSubmit: () => void;
  /** Whether input is disabled */
  disabled?: boolean;
  /** Placeholder text */
  placeholder?: string;
  /** Enable multiline mode (Shift+Enter for newlines) */
  multiline?: boolean;
  /** Called on up arrow (for history navigation) */
  onHistoryUp?: () => void;
  /** Called on down arrow (for history navigation) */
  onHistoryDown?: () => void;
}

export function EnhancedInput({
  value,
  onChange,
  onSubmit,
  disabled = false,
  placeholder = '',
  multiline = false,
  onHistoryUp,
  onHistoryDown,
}: EnhancedInputProps): React.ReactElement {
  const inputRef = useRef(new MultilineInput());
  const { isFocused } = useFocus({ autoFocus: true });

  // Sync external value to internal state
  useEffect(() => {
    if (inputRef.current.getValue() !== value) {
      inputRef.current.setValue(value);
    }
  }, [value]);

  // Helper to update external value
  const updateValue = useCallback(() => {
    onChange(inputRef.current.getValue());
  }, [onChange]);

  useInput((input, key) => {
    if (disabled) return;

    const inp = inputRef.current;

    // Handle Enter key
    if (key.return) {
      if (multiline && key.shift) {
        // Shift+Enter: Insert newline in multiline mode
        inp.insertNewline();
        updateValue();
      } else {
        // Enter: Submit
        onSubmit();
      }
      return;
    }

    // Handle Escape
    if (key.escape) {
      inp.clear();
      updateValue();
      return;
    }

    // Handle Backspace with modifiers
    if (key.backspace) {
      if (key.meta) {
        // Cmd+Backspace: Delete to start of line
        inp.deleteToLineStart();
      } else {
        // Regular Backspace
        inp.backspace();
      }
      updateValue();
      return;
    }

    // Handle Delete key (forward delete)
    if (key.delete) {
      inp.delete();
      updateValue();
      return;
    }

    // Handle Arrow keys
    if (key.leftArrow) {
      if (key.meta) {
        // Cmd+Left: Move to start of line
        inp.moveCursorToLineStart();
      } else {
        // Regular Left
        inp.moveCursor(-1);
      }
      return;
    }

    if (key.rightArrow) {
      if (key.meta) {
        // Cmd+Right: Move to end of line
        inp.moveCursorToLineEnd();
      } else {
        // Regular Right
        inp.moveCursor(1);
      }
      return;
    }

    if (key.upArrow) {
      if (multiline && inp.getCursorRow() > 0) {
        // In multiline, navigate within lines
        inp.moveToPreviousLine();
      } else if (onHistoryUp) {
        // Otherwise trigger history navigation
        onHistoryUp();
      }
      return;
    }

    if (key.downArrow) {
      if (multiline && inp.getCursorRow() < inp.getLineCount() - 1) {
        // In multiline, navigate within lines
        inp.moveToNextLine();
      } else if (onHistoryDown) {
        // Otherwise trigger history navigation
        onHistoryDown();
      }
      return;
    }

    // Handle Ctrl+A (start of line)
    if (input === 'a' && key.ctrl) {
      inp.moveCursorToLineStart();
      return;
    }

    // Handle Ctrl+E (end of line)
    if (input === 'e' && key.ctrl) {
      inp.moveCursorToLineEnd();
      return;
    }

    // Handle Ctrl+K (kill to end of line)
    if (input === 'k' && key.ctrl) {
      inp.deleteToLineEnd();
      updateValue();
      return;
    }

    // Handle Ctrl+U (kill to start of line)
    if (input === 'u' && key.ctrl) {
      inp.deleteToLineStart();
      updateValue();
      return;
    }

    // Handle Ctrl+W (delete word before cursor)
    if (input === 'w' && key.ctrl) {
      inp.deleteWordBefore();
      updateValue();
      return;
    }

    // Skip non-printable characters
    if (!input || key.ctrl || key.meta) {
      return;
    }

    // Regular character input
    inp.insertText(input);
    updateValue();
  }, { isActive: isFocused && !disabled });

  // Render the input display
  const displayValue = value || '';
  const cursorPos = inputRef.current.getCursorPosition();
  const showPlaceholder = !displayValue && placeholder;

  // Split value at cursor for display
  const beforeCursor = displayValue.slice(0, cursorPos);
  const cursorChar = displayValue[cursorPos] || ' ';
  const afterCursor = displayValue.slice(cursorPos + 1);

  return (
    <Box>
      {showPlaceholder ? (
        <Text color="gray">{placeholder}</Text>
      ) : (
        <>
          <Text>{beforeCursor}</Text>
          <Text inverse={isFocused && !disabled}>{cursorChar}</Text>
          <Text>{afterCursor}</Text>
        </>
      )}
    </Box>
  );
}
