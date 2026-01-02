/**
 * @fileoverview macOS-compatible Text Input Component
 *
 * Custom text input that supports standard macOS keyboard shortcuts:
 *
 * Navigation:
 * - Left/Right: Move cursor by character
 * - Option+Left/Right: Move cursor by word
 * - Ctrl+A / Cmd+Left: Move to start of line
 * - Ctrl+E / Cmd+Right: Move to end of line
 *
 * Selection (with Shift):
 * - Shift+Left/Right: Select character by character
 * - Shift+Option+Left/Right: Select word by word
 * - Shift+Ctrl+A / Shift+Cmd+Left: Select to start of line
 * - Shift+Ctrl+E / Shift+Cmd+Right: Select to end of line
 *
 * Deletion:
 * - Backspace/Delete: Delete character (or selection)
 * - Option+Backspace: Delete word before cursor
 * - Ctrl+U / Cmd+Delete: Delete to start of line
 * - Ctrl+K: Delete to end of line
 * - Ctrl+W: Delete word before cursor
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
  // Cursor position
  const [cursorOffset, setCursorOffset] = useState(value.length);
  // Selection anchor - null means no selection, otherwise it's where selection started
  const [selectionAnchor, setSelectionAnchor] = useState<number | null>(null);

  // Keep cursor in bounds when value changes externally
  useEffect(() => {
    if (cursorOffset > value.length) {
      setCursorOffset(value.length);
    }
    if (selectionAnchor !== null && selectionAnchor > value.length) {
      setSelectionAnchor(value.length);
    }
  }, [value, cursorOffset, selectionAnchor]);

  // Reset cursor to end when value is set externally (e.g., history navigation)
  useEffect(() => {
    setCursorOffset(value.length);
    setSelectionAnchor(null);
  }, [value]);

  // Get selection range (start, end) - returns null if no selection
  const getSelectionRange = useCallback((): { start: number; end: number } | null => {
    if (selectionAnchor === null) return null;
    if (selectionAnchor === cursorOffset) return null;
    return {
      start: Math.min(selectionAnchor, cursorOffset),
      end: Math.max(selectionAnchor, cursorOffset),
    };
  }, [selectionAnchor, cursorOffset]);

  // Check if there's an active selection
  const hasSelection = useCallback((): boolean => {
    return getSelectionRange() !== null;
  }, [getSelectionRange]);

  // Clear selection
  const clearSelection = useCallback(() => {
    setSelectionAnchor(null);
  }, []);

  // Start or extend selection
  const extendSelection = useCallback((newCursor: number) => {
    if (selectionAnchor === null) {
      // Start new selection from current cursor position
      setSelectionAnchor(cursorOffset);
    }
    setCursorOffset(newCursor);
  }, [selectionAnchor, cursorOffset]);

  // Move cursor and clear selection
  const moveCursor = useCallback((newCursor: number) => {
    setCursorOffset(Math.max(0, Math.min(newCursor, value.length)));
    clearSelection();
  }, [value.length, clearSelection]);

  // Update value and cursor, clearing selection
  const updateValue = useCallback(
    (newValue: string, newCursor: number) => {
      onChange(newValue);
      setCursorOffset(Math.max(0, Math.min(newCursor, newValue.length)));
      clearSelection();
    },
    [onChange, clearSelection]
  );

  // Delete selection and return new value/cursor, or return null if no selection
  const deleteSelection = useCallback((): { newValue: string; newCursor: number } | null => {
    const range = getSelectionRange();
    if (!range) return null;
    const newValue = value.slice(0, range.start) + value.slice(range.end);
    return { newValue, newCursor: range.start };
  }, [value, getSelectionRange]);

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

      // Handle Up/Down arrows for history (only when no selection)
      if (key.upArrow && !key.shift) {
        clearSelection();
        onUpArrow?.();
        return;
      }
      if (key.downArrow && !key.shift) {
        clearSelection();
        onDownArrow?.();
        return;
      }

      // === Selection with Shift ===

      // Shift+Ctrl+A: Select to start of line
      if (key.shift && key.ctrl && input === 'a') {
        extendSelection(0);
        return;
      }

      // Shift+Ctrl+E: Select to end of line
      if (key.shift && key.ctrl && input === 'e') {
        extendSelection(value.length);
        return;
      }

      // Shift+Option+Left: Select word left
      if (key.shift && key.meta && key.leftArrow) {
        extendSelection(findWordBoundaryLeft(cursorOffset));
        return;
      }

      // Shift+Option+Right: Select word right
      if (key.shift && key.meta && key.rightArrow) {
        extendSelection(findWordBoundaryRight(cursorOffset));
        return;
      }

      // Shift+Left: Select character left
      if (key.shift && key.leftArrow) {
        if (cursorOffset > 0) {
          extendSelection(cursorOffset - 1);
        }
        return;
      }

      // Shift+Right: Select character right
      if (key.shift && key.rightArrow) {
        if (cursorOffset < value.length) {
          extendSelection(cursorOffset + 1);
        }
        return;
      }

      // === Navigation (non-shift) ===

      // Ctrl+U: Delete to start of line (Cmd+Delete in many terminals)
      if (key.ctrl && input === 'u') {
        // If there's a selection, delete it first
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) {
            updateValue(result.newValue, result.newCursor);
          }
        } else {
          const newValue = value.slice(cursorOffset);
          updateValue(newValue, 0);
        }
        return;
      }

      // Ctrl+K: Delete to end of line
      if (key.ctrl && input === 'k') {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) {
            updateValue(result.newValue, result.newCursor);
          }
        } else {
          const newValue = value.slice(0, cursorOffset);
          updateValue(newValue, cursorOffset);
        }
        return;
      }

      // Ctrl+A: Move to start of line (Cmd+Left in many terminals)
      if (key.ctrl && input === 'a') {
        moveCursor(0);
        return;
      }

      // Ctrl+E: Move to end of line (Cmd+Right in many terminals)
      if (key.ctrl && input === 'e') {
        moveCursor(value.length);
        return;
      }

      // Ctrl+W: Delete word before cursor
      if (key.ctrl && input === 'w') {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) {
            updateValue(result.newValue, result.newCursor);
          }
        } else {
          const wordStart = findWordBoundaryLeft(cursorOffset);
          const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
          updateValue(newValue, wordStart);
        }
        return;
      }

      // Option+Left: Move cursor word left
      if (key.meta && key.leftArrow) {
        moveCursor(findWordBoundaryLeft(cursorOffset));
        return;
      }

      // Option+Right: Move cursor word right
      if (key.meta && key.rightArrow) {
        moveCursor(findWordBoundaryRight(cursorOffset));
        return;
      }

      // Option+Backspace or Option+Delete: Delete word before cursor
      if (key.meta && (key.backspace || key.delete)) {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) {
            updateValue(result.newValue, result.newCursor);
          }
        } else {
          const wordStart = findWordBoundaryLeft(cursorOffset);
          const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
          updateValue(newValue, wordStart);
        }
        return;
      }

      // Regular left arrow - move cursor or collapse selection
      if (key.leftArrow) {
        if (hasSelection()) {
          // Collapse selection to the left side
          const range = getSelectionRange();
          if (range) {
            moveCursor(range.start);
          }
        } else {
          moveCursor(cursorOffset - 1);
        }
        return;
      }

      // Regular right arrow - move cursor or collapse selection
      if (key.rightArrow) {
        if (hasSelection()) {
          // Collapse selection to the right side
          const range = getSelectionRange();
          if (range) {
            moveCursor(range.end);
          }
        } else {
          moveCursor(cursorOffset + 1);
        }
        return;
      }

      // Regular backspace/delete
      if (key.backspace || key.delete) {
        if (hasSelection()) {
          // Delete selection
          const result = deleteSelection();
          if (result) {
            updateValue(result.newValue, result.newCursor);
          }
        } else if (cursorOffset > 0) {
          const newValue =
            value.slice(0, cursorOffset - 1) + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset - 1);
        }
        return;
      }

      // Escape key - clear selection
      if (key.escape) {
        clearSelection();
        return;
      }

      // Regular character input
      if (input && !key.ctrl && !key.meta) {
        if (hasSelection()) {
          // Replace selection with typed character
          const range = getSelectionRange();
          if (range) {
            const newValue = value.slice(0, range.start) + input + value.slice(range.end);
            updateValue(newValue, range.start + input.length);
          }
        } else {
          const newValue =
            value.slice(0, cursorOffset) + input + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset + input.length);
        }
      }
    },
    { isActive: focus }
  );

  // Render the input with cursor and selection highlighting
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

    const range = getSelectionRange();

    let rendered = '';
    for (let i = 0; i < value.length; i++) {
      const char = value[i] ?? '';
      const isSelected = range && i >= range.start && i < range.end;
      const isCursor = i === cursorOffset;

      if (isSelected) {
        // Selected text - use cyan background
        rendered += chalk.bgCyan.black(char);
      } else if (isCursor) {
        // Cursor position - inverse
        rendered += chalk.inverse(char);
      } else {
        rendered += char;
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
