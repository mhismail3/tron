/**
 * @fileoverview macOS-compatible Text Input Component
 *
 * Custom text input that supports standard macOS keyboard shortcuts:
 * - Option+Delete/Backspace: Delete word before cursor
 * - Cmd+Delete (via Ctrl+U): Delete to start of line
 * - Option+Left/Right: Move cursor by word
 * - Cmd+Left/Right (via Ctrl+A/E): Move to start/end of line
 * - Ctrl+K: Delete to end of line
 */
import React, { useState, useCallback, useEffect } from 'react';
import { Text, useInput } from 'ink';
import chalk from 'chalk';

export interface MacOSInputProps {
  /** Current input value */
  value: string;
  /** Callback when value changes */
  onChange: (value: string) => void;
  /** Callback when Enter is pressed */
  onSubmit?: () => void;
  /** Placeholder text when empty */
  placeholder?: string;
  /** Whether input is focused */
  focus?: boolean;
  /** Callback for up arrow (history navigation) */
  onUpArrow?: () => void;
  /** Callback for down arrow (history navigation) */
  onDownArrow?: () => void;
}

export function MacOSInput({
  value,
  onChange,
  onSubmit,
  placeholder = '',
  focus = true,
  onUpArrow,
  onDownArrow,
}: MacOSInputProps): React.ReactElement {
  const [cursorOffset, setCursorOffset] = useState(value.length);

  // Keep cursor in bounds when value changes externally
  useEffect(() => {
    if (cursorOffset > value.length) {
      setCursorOffset(value.length);
    }
  }, [value, cursorOffset]);

  // Reset cursor to end when value is set externally (e.g., history navigation)
  useEffect(() => {
    setCursorOffset(value.length);
  }, [value]);

  const updateValue = useCallback(
    (newValue: string, newCursor: number) => {
      onChange(newValue);
      setCursorOffset(Math.max(0, Math.min(newCursor, newValue.length)));
    },
    [onChange]
  );

  // Find word boundary going left
  const findWordBoundaryLeft = useCallback(
    (pos: number): number => {
      if (pos === 0) return 0;
      let newPos = pos;
      // Skip whitespace first
      while (newPos > 0 && /\s/.test(value[newPos - 1] ?? '')) {
        newPos--;
      }
      // Then skip word characters
      while (newPos > 0 && !/\s/.test(value[newPos - 1] ?? '')) {
        newPos--;
      }
      return newPos;
    },
    [value]
  );

  // Find word boundary going right
  const findWordBoundaryRight = useCallback(
    (pos: number): number => {
      if (pos >= value.length) return value.length;
      let newPos = pos;
      // Skip current word first
      while (newPos < value.length && !/\s/.test(value[newPos] ?? '')) {
        newPos++;
      }
      // Then skip whitespace
      while (newPos < value.length && /\s/.test(value[newPos] ?? '')) {
        newPos++;
      }
      return newPos;
    },
    [value]
  );

  useInput(
    (input, key) => {
      // Handle Ctrl+C (let it propagate for exit)
      if (key.ctrl && input === 'c') {
        return;
      }

      // Handle Tab (let it propagate)
      if (key.tab) {
        return;
      }

      // Handle Enter/Return
      if (key.return) {
        onSubmit?.();
        return;
      }

      // Handle Up/Down arrows for history
      if (key.upArrow) {
        onUpArrow?.();
        return;
      }
      if (key.downArrow) {
        onDownArrow?.();
        return;
      }

      // === macOS Keyboard Shortcuts ===

      // Ctrl+U: Delete to start of line (Cmd+Delete in many terminals)
      if (key.ctrl && input === 'u') {
        const newValue = value.slice(cursorOffset);
        updateValue(newValue, 0);
        return;
      }

      // Ctrl+K: Delete to end of line
      if (key.ctrl && input === 'k') {
        const newValue = value.slice(0, cursorOffset);
        updateValue(newValue, cursorOffset);
        return;
      }

      // Ctrl+A: Move to start of line (Cmd+Left in many terminals)
      if (key.ctrl && input === 'a') {
        setCursorOffset(0);
        return;
      }

      // Ctrl+E: Move to end of line (Cmd+Right in many terminals)
      if (key.ctrl && input === 'e') {
        setCursorOffset(value.length);
        return;
      }

      // Ctrl+W: Delete word before cursor (alternative to Option+Delete)
      if (key.ctrl && input === 'w') {
        const wordStart = findWordBoundaryLeft(cursorOffset);
        const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
        updateValue(newValue, wordStart);
        return;
      }

      // Option+Left: Move cursor word left
      if (key.meta && key.leftArrow) {
        setCursorOffset(findWordBoundaryLeft(cursorOffset));
        return;
      }

      // Option+Right: Move cursor word right
      if (key.meta && key.rightArrow) {
        setCursorOffset(findWordBoundaryRight(cursorOffset));
        return;
      }

      // Option+Backspace or Option+Delete: Delete word before cursor
      // When Option is pressed with delete/backspace, key.meta is true
      if (key.meta && (key.backspace || key.delete)) {
        const wordStart = findWordBoundaryLeft(cursorOffset);
        const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
        updateValue(newValue, wordStart);
        return;
      }

      // Regular left arrow
      if (key.leftArrow) {
        setCursorOffset(Math.max(0, cursorOffset - 1));
        return;
      }

      // Regular right arrow
      if (key.rightArrow) {
        setCursorOffset(Math.min(value.length, cursorOffset + 1));
        return;
      }

      // Regular backspace
      if (key.backspace || key.delete) {
        if (cursorOffset > 0) {
          const newValue =
            value.slice(0, cursorOffset - 1) + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset - 1);
        }
        return;
      }

      // Escape key - ignore
      if (key.escape) {
        return;
      }

      // Regular character input
      if (input && !key.ctrl && !key.meta) {
        const newValue =
          value.slice(0, cursorOffset) + input + value.slice(cursorOffset);
        updateValue(newValue, cursorOffset + input.length);
      }
    },
    { isActive: focus }
  );

  // Render the input with cursor
  const renderValue = (): string => {
    if (!focus) {
      return value || placeholder;
    }

    if (value.length === 0) {
      if (placeholder) {
        return chalk.inverse(placeholder[0] ?? ' ') + chalk.gray(placeholder.slice(1));
      }
      return chalk.inverse(' ');
    }

    let rendered = '';
    for (let i = 0; i < value.length; i++) {
      if (i === cursorOffset) {
        rendered += chalk.inverse(value[i]);
      } else {
        rendered += value[i];
      }
    }

    // If cursor is at the end, show cursor after last character
    if (cursorOffset === value.length) {
      rendered += chalk.inverse(' ');
    }

    return rendered;
  };

  return <Text>{renderValue()}</Text>;
}
