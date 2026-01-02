/**
 * @fileoverview macOS-compatible Multiline Text Input Component
 *
 * Full-featured text input with standard macOS keyboard shortcuts:
 *
 * Navigation:
 * - Left/Right: Move cursor by character
 * - Up/Down: Move cursor between lines (or history if single line)
 * - Option+Left/Right (or Esc+b/f): Move cursor by word
 * - Ctrl+A / Home: Move to start of line
 * - Ctrl+E / End: Move to end of line
 *
 * Selection (with Shift):
 * - Shift+Left/Right: Select character by character
 * - Shift+Up/Down: Select line by line
 * - Shift+Option+Left/Right: Select word by word
 * - Shift+Ctrl+A: Select to start of line
 * - Shift+Ctrl+E: Select to end of line
 * - Ctrl+Shift+A or Ctrl+A (when text exists): Select all
 *
 * Editing:
 * - Backspace/Delete: Delete character (or selection)
 * - Option+Backspace (or Esc+Backspace): Delete word before cursor
 * - Ctrl+U: Delete to start of line
 * - Ctrl+K: Delete to end of line
 * - Ctrl+W: Delete word before cursor
 * - Shift+Enter: Insert newline
 *
 * Undo/Redo:
 * - Ctrl+Z: Undo
 * - Ctrl+Y or Ctrl+Shift+Z: Redo
 */
import React, { useState, useCallback, useEffect, useRef } from 'react';
import { Text, useInput } from 'ink';
import chalk from 'chalk';

// =============================================================================
// Types
// =============================================================================

interface UndoState {
  value: string;
  cursorOffset: number;
}

export interface MacOSInputProps {
  /** Current input value */
  value: string;
  /** Callback when value changes */
  onChange: (value: string) => void;
  /** Callback when Enter is pressed (submit) */
  onSubmit?: () => void;
  /** Placeholder text when empty */
  placeholder?: string;
  /** Whether input is focused */
  focus?: boolean;
  /** Callback for history up (only when cursor at first line) */
  onHistoryUp?: () => void;
  /** Callback for history down (only when cursor at last line) */
  onHistoryDown?: () => void;
  /** Maximum visible lines before scrolling (0 = unlimited) */
  maxVisibleLines?: number;
  /** Terminal width for wrapping calculation */
  terminalWidth?: number;
  /** Background color for the input area */
  backgroundColor?: 'gray' | 'black' | 'white' | 'red' | 'green' | 'yellow' | 'blue' | 'magenta' | 'cyan';
  /** Prefix to add to continuation lines (lines after the first) for alignment */
  continuationPrefix?: string;
}

// =============================================================================
// Component
// =============================================================================

export function MacOSInput({
  value,
  onChange,
  onSubmit,
  placeholder = '',
  focus = true,
  onHistoryUp,
  onHistoryDown,
  maxVisibleLines = 20,
  terminalWidth: _terminalWidth = 80,
  continuationPrefix = '',
}: MacOSInputProps): React.ReactElement {
  // Cursor position (character index in the string)
  const [cursorOffset, setCursorOffset] = useState(value.length);
  // Selection anchor - null means no selection
  const [selectionAnchor, setSelectionAnchor] = useState<number | null>(null);
  // Scroll offset for multiline (which line is at the top)
  const [scrollOffset, setScrollOffset] = useState(0);
  // Undo/Redo stacks
  const undoStack = useRef<UndoState[]>([]);
  const redoStack = useRef<UndoState[]>([]);
  // Track if last change was from undo/redo to avoid pushing to stack
  const isUndoRedo = useRef(false);

  // ==========================================================================
  // Cursor and Selection Helpers
  // ==========================================================================

  // Keep cursor in bounds when value changes externally
  useEffect(() => {
    if (cursorOffset > value.length) {
      setCursorOffset(value.length);
    }
    if (selectionAnchor !== null && selectionAnchor > value.length) {
      setSelectionAnchor(value.length);
    }
  }, [value, cursorOffset, selectionAnchor]);

  // Reset cursor to end when value changes externally (e.g., history navigation)
  // Only if not from undo/redo
  useEffect(() => {
    if (!isUndoRedo.current) {
      setCursorOffset(value.length);
      setSelectionAnchor(null);
    }
    isUndoRedo.current = false;
  }, [value]);

  // Get selection range
  const getSelectionRange = useCallback((): { start: number; end: number } | null => {
    if (selectionAnchor === null || selectionAnchor === cursorOffset) return null;
    return {
      start: Math.min(selectionAnchor, cursorOffset),
      end: Math.max(selectionAnchor, cursorOffset),
    };
  }, [selectionAnchor, cursorOffset]);

  const hasSelection = useCallback((): boolean => {
    return getSelectionRange() !== null;
  }, [getSelectionRange]);

  const clearSelection = useCallback(() => {
    setSelectionAnchor(null);
  }, []);

  const extendSelection = useCallback((newCursor: number) => {
    if (selectionAnchor === null) {
      setSelectionAnchor(cursorOffset);
    }
    setCursorOffset(Math.max(0, Math.min(newCursor, value.length)));
  }, [selectionAnchor, cursorOffset, value.length]);

  const moveCursor = useCallback((newCursor: number) => {
    setCursorOffset(Math.max(0, Math.min(newCursor, value.length)));
    clearSelection();
  }, [value.length, clearSelection]);

  // ==========================================================================
  // Undo/Redo
  // ==========================================================================

  const pushUndoState = useCallback(() => {
    undoStack.current.push({ value, cursorOffset });
    // Limit undo stack size
    if (undoStack.current.length > 100) {
      undoStack.current.shift();
    }
    // Clear redo stack on new action
    redoStack.current = [];
  }, [value, cursorOffset]);

  const undo = useCallback(() => {
    if (undoStack.current.length === 0) return;
    // Save current state to redo
    redoStack.current.push({ value, cursorOffset });
    // Restore previous state
    const prevState = undoStack.current.pop()!;
    isUndoRedo.current = true;
    onChange(prevState.value);
    setCursorOffset(prevState.cursorOffset);
    clearSelection();
  }, [value, cursorOffset, onChange, clearSelection]);

  const redo = useCallback(() => {
    if (redoStack.current.length === 0) return;
    // Save current state to undo
    undoStack.current.push({ value, cursorOffset });
    // Restore next state
    const nextState = redoStack.current.pop()!;
    isUndoRedo.current = true;
    onChange(nextState.value);
    setCursorOffset(nextState.cursorOffset);
    clearSelection();
  }, [value, cursorOffset, onChange, clearSelection]);

  // ==========================================================================
  // Value Update Helpers
  // ==========================================================================

  const updateValue = useCallback(
    (newValue: string, newCursor: number) => {
      pushUndoState();
      onChange(newValue);
      setCursorOffset(Math.max(0, Math.min(newCursor, newValue.length)));
      clearSelection();
    },
    [onChange, clearSelection, pushUndoState]
  );

  const deleteSelection = useCallback((): { newValue: string; newCursor: number } | null => {
    const range = getSelectionRange();
    if (!range) return null;
    const newValue = value.slice(0, range.start) + value.slice(range.end);
    return { newValue, newCursor: range.start };
  }, [value, getSelectionRange]);

  // ==========================================================================
  // Word Boundary Helpers
  // ==========================================================================

  const findWordBoundaryLeft = useCallback((pos: number): number => {
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
  }, [value]);

  const findWordBoundaryRight = useCallback((pos: number): number => {
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
  }, [value]);

  // ==========================================================================
  // Line Navigation Helpers
  // ==========================================================================

  const getLines = useCallback((): string[] => {
    return value.split('\n');
  }, [value]);

  const getCursorLineAndColumn = useCallback((): { line: number; column: number } => {
    const beforeCursor = value.slice(0, cursorOffset);
    const lines = beforeCursor.split('\n');
    return {
      line: lines.length - 1,
      column: lines[lines.length - 1]?.length ?? 0,
    };
  }, [value, cursorOffset]);

  const getPositionFromLineColumn = useCallback((line: number, column: number): number => {
    const lines = getLines();
    let pos = 0;
    for (let i = 0; i < line && i < lines.length; i++) {
      pos += (lines[i]?.length ?? 0) + 1; // +1 for newline
    }
    const targetLine = lines[line] ?? '';
    pos += Math.min(column, targetLine.length);
    return Math.min(pos, value.length);
  }, [value, getLines]);

  const moveCursorVertically = useCallback((direction: 'up' | 'down'): boolean => {
    const { line, column } = getCursorLineAndColumn();
    const lines = getLines();
    const newLine = direction === 'up' ? line - 1 : line + 1;

    if (newLine < 0 || newLine >= lines.length) {
      return false; // Can't move, at boundary
    }

    const newPos = getPositionFromLineColumn(newLine, column);
    moveCursor(newPos);
    return true;
  }, [getCursorLineAndColumn, getLines, getPositionFromLineColumn, moveCursor]);

  const extendSelectionVertically = useCallback((direction: 'up' | 'down'): boolean => {
    const { line, column } = getCursorLineAndColumn();
    const lines = getLines();
    const newLine = direction === 'up' ? line - 1 : line + 1;

    if (newLine < 0 || newLine >= lines.length) {
      return false;
    }

    const newPos = getPositionFromLineColumn(newLine, column);
    extendSelection(newPos);
    return true;
  }, [getCursorLineAndColumn, getLines, getPositionFromLineColumn, extendSelection]);

  const isMultiline = value.includes('\n');
  const isAtFirstLine = getCursorLineAndColumn().line === 0;
  const isAtLastLine = getCursorLineAndColumn().line === getLines().length - 1;

  // ==========================================================================
  // Input Handler
  // ==========================================================================

  useInput(
    (input, key) => {
      // Ctrl+C - let it propagate for exit
      if (key.ctrl && input === 'c') {
        return;
      }

      // Tab - let it propagate
      if (key.tab) {
        return;
      }

      // Enter - submit (without shift)
      if (key.return && !key.shift) {
        onSubmit?.();
        return;
      }

      // Shift+Enter - insert newline
      if (key.return && key.shift) {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) {
            const newValue = result.newValue.slice(0, result.newCursor) + '\n' + result.newValue.slice(result.newCursor);
            updateValue(newValue, result.newCursor + 1);
          }
        } else {
          const newValue = value.slice(0, cursorOffset) + '\n' + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset + 1);
        }
        return;
      }

      // === Undo/Redo ===

      // Ctrl+Z - Undo
      if (key.ctrl && input === 'z' && !key.shift) {
        undo();
        return;
      }

      // Ctrl+Y or Ctrl+Shift+Z - Redo
      if ((key.ctrl && input === 'y') || (key.ctrl && key.shift && input === 'z')) {
        redo();
        return;
      }

      // === Select All ===
      // Ctrl+Shift+A - Select all (avoiding conflict with Ctrl+A for start of line)
      if (key.ctrl && key.shift && input === 'a') {
        setSelectionAnchor(0);
        setCursorOffset(value.length);
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

      // Shift+Option+Left (also Shift+Esc+b): Select word left
      if (key.shift && key.meta && (key.leftArrow || input === 'b' || input === 'B')) {
        extendSelection(findWordBoundaryLeft(cursorOffset));
        return;
      }

      // Shift+Option+Right (also Shift+Esc+f): Select word right
      if (key.shift && key.meta && (key.rightArrow || input === 'f' || input === 'F')) {
        extendSelection(findWordBoundaryRight(cursorOffset));
        return;
      }

      // Shift+Up: Select line up
      if (key.shift && key.upArrow) {
        extendSelectionVertically('up');
        return;
      }

      // Shift+Down: Select line down
      if (key.shift && key.downArrow) {
        extendSelectionVertically('down');
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

      // === Navigation ===

      // Ctrl+U: Delete to start of line
      if (key.ctrl && input === 'u') {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) updateValue(result.newValue, result.newCursor);
        } else {
          // Find start of current line
          const beforeCursor = value.slice(0, cursorOffset);
          const lastNewline = beforeCursor.lastIndexOf('\n');
          const lineStart = lastNewline === -1 ? 0 : lastNewline + 1;
          const newValue = value.slice(0, lineStart) + value.slice(cursorOffset);
          updateValue(newValue, lineStart);
        }
        return;
      }

      // Ctrl+K: Delete to end of line
      if (key.ctrl && input === 'k') {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) updateValue(result.newValue, result.newCursor);
        } else {
          // Find end of current line
          const afterCursor = value.slice(cursorOffset);
          const nextNewline = afterCursor.indexOf('\n');
          const lineEnd = nextNewline === -1 ? value.length : cursorOffset + nextNewline;
          const newValue = value.slice(0, cursorOffset) + value.slice(lineEnd);
          updateValue(newValue, cursorOffset);
        }
        return;
      }

      // Ctrl+A: Move to start of line
      if (key.ctrl && input === 'a') {
        // Find start of current line
        const beforeCursor = value.slice(0, cursorOffset);
        const lastNewline = beforeCursor.lastIndexOf('\n');
        const lineStart = lastNewline === -1 ? 0 : lastNewline + 1;
        moveCursor(lineStart);
        return;
      }

      // Ctrl+E: Move to end of line
      if (key.ctrl && input === 'e') {
        // Find end of current line
        const afterCursor = value.slice(cursorOffset);
        const nextNewline = afterCursor.indexOf('\n');
        const lineEnd = nextNewline === -1 ? value.length : cursorOffset + nextNewline;
        moveCursor(lineEnd);
        return;
      }

      // Ctrl+W: Delete word before cursor
      if (key.ctrl && input === 'w') {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) updateValue(result.newValue, result.newCursor);
        } else {
          const wordStart = findWordBoundaryLeft(cursorOffset);
          const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
          updateValue(newValue, wordStart);
        }
        return;
      }

      // Option+Left (also Esc+b): Move cursor word left
      if (key.meta && (key.leftArrow || input === 'b')) {
        moveCursor(findWordBoundaryLeft(cursorOffset));
        return;
      }

      // Option+Right (also Esc+f): Move cursor word right
      if (key.meta && (key.rightArrow || input === 'f')) {
        moveCursor(findWordBoundaryRight(cursorOffset));
        return;
      }

      // Option+Backspace (also Esc+Backspace): Delete word before cursor
      if (key.meta && (key.backspace || key.delete)) {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) updateValue(result.newValue, result.newCursor);
        } else {
          const wordStart = findWordBoundaryLeft(cursorOffset);
          const newValue = value.slice(0, wordStart) + value.slice(cursorOffset);
          updateValue(newValue, wordStart);
        }
        return;
      }

      // Up arrow
      if (key.upArrow) {
        if (isMultiline && !isAtFirstLine) {
          // Navigate within multiline text
          moveCursorVertically('up');
        } else {
          // At first line or single line - trigger history
          clearSelection();
          onHistoryUp?.();
        }
        return;
      }

      // Down arrow
      if (key.downArrow) {
        if (isMultiline && !isAtLastLine) {
          // Navigate within multiline text
          moveCursorVertically('down');
        } else {
          // At last line or single line - trigger history
          clearSelection();
          onHistoryDown?.();
        }
        return;
      }

      // Left arrow
      if (key.leftArrow) {
        if (hasSelection()) {
          const range = getSelectionRange();
          if (range) moveCursor(range.start);
        } else {
          moveCursor(cursorOffset - 1);
        }
        return;
      }

      // Right arrow
      if (key.rightArrow) {
        if (hasSelection()) {
          const range = getSelectionRange();
          if (range) moveCursor(range.end);
        } else {
          moveCursor(cursorOffset + 1);
        }
        return;
      }

      // Backspace/Delete
      if (key.backspace || key.delete) {
        if (hasSelection()) {
          const result = deleteSelection();
          if (result) updateValue(result.newValue, result.newCursor);
        } else if (cursorOffset > 0) {
          const newValue = value.slice(0, cursorOffset - 1) + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset - 1);
        }
        return;
      }

      // Escape - clear selection
      if (key.escape) {
        clearSelection();
        return;
      }

      // Regular character input
      if (input && !key.ctrl && !key.meta) {
        if (hasSelection()) {
          const range = getSelectionRange();
          if (range) {
            const newValue = value.slice(0, range.start) + input + value.slice(range.end);
            updateValue(newValue, range.start + input.length);
          }
        } else {
          const newValue = value.slice(0, cursorOffset) + input + value.slice(cursorOffset);
          updateValue(newValue, cursorOffset + input.length);
        }
      }
    },
    { isActive: focus }
  );

  // ==========================================================================
  // Scroll Management
  // ==========================================================================

  useEffect(() => {
    if (maxVisibleLines <= 0) return;

    const { line } = getCursorLineAndColumn();
    const totalLines = getLines().length;

    // Adjust scroll to keep cursor visible
    if (line < scrollOffset) {
      setScrollOffset(line);
    } else if (line >= scrollOffset + maxVisibleLines) {
      setScrollOffset(line - maxVisibleLines + 1);
    }

    // Ensure scroll doesn't exceed bounds
    const maxScroll = Math.max(0, totalLines - maxVisibleLines);
    if (scrollOffset > maxScroll) {
      setScrollOffset(maxScroll);
    }
  }, [cursorOffset, value, maxVisibleLines, scrollOffset, getCursorLineAndColumn, getLines]);

  // ==========================================================================
  // Render
  // ==========================================================================

  const renderValue = (): string => {
    if (!focus) {
      return value || chalk.gray(placeholder);
    }

    if (value.length === 0) {
      if (placeholder) {
        return chalk.inverse(placeholder[0] ?? ' ') + chalk.gray(placeholder.slice(1));
      }
      return chalk.inverse(' ');
    }

    const range = getSelectionRange();
    const lines = getLines();
    const totalLines = lines.length;

    // Determine visible lines
    const startLine = maxVisibleLines > 0 ? scrollOffset : 0;
    const endLine = maxVisibleLines > 0 ? Math.min(startLine + maxVisibleLines, totalLines) : totalLines;

    // Calculate character positions for visible region
    let charOffset = 0;
    for (let i = 0; i < startLine; i++) {
      charOffset += (lines[i]?.length ?? 0) + 1;
    }

    const renderedLines: string[] = [];
    let currentCharPos = charOffset;

    for (let lineIdx = startLine; lineIdx < endLine; lineIdx++) {
      const line = lines[lineIdx] ?? '';
      let renderedLine = '';

      for (let i = 0; i < line.length; i++) {
        const globalPos = currentCharPos + i;
        const char = line[i] ?? '';
        const isSelected = range && globalPos >= range.start && globalPos < range.end;
        const isCursor = globalPos === cursorOffset;

        if (isSelected) {
          renderedLine += chalk.bgCyan.black(char);
        } else if (isCursor) {
          renderedLine += chalk.inverse(char);
        } else {
          renderedLine += char;
        }
      }

      // Check if cursor is at end of this line (before newline or at end of value)
      const endOfLinePos = currentCharPos + line.length;
      if (cursorOffset === endOfLinePos && lineIdx < totalLines - 1) {
        // Cursor at end of line (before newline)
        renderedLine += chalk.inverse(' ');
      } else if (cursorOffset === endOfLinePos && lineIdx === totalLines - 1) {
        // Cursor at very end of value
        renderedLine += chalk.inverse(' ');
      }

      renderedLines.push(renderedLine);
      currentCharPos += line.length + 1; // +1 for newline
    }

    // Add continuation prefix to lines after the first (for alignment with prompt)
    const prefixedLines = renderedLines.map((line, idx) => {
      // First visible line doesn't get prefix (PromptBox adds "> ")
      // Subsequent lines get the continuation prefix for alignment
      if (idx === 0) return line;
      return continuationPrefix + line;
    });

    // Add scroll indicators if needed
    let result = prefixedLines.join('\n');
    if (maxVisibleLines > 0 && totalLines > maxVisibleLines) {
      if (scrollOffset > 0) {
        result = chalk.gray(`${continuationPrefix}↑ ${scrollOffset} more line${scrollOffset > 1 ? 's' : ''}\n`) + result;
      }
      const remaining = totalLines - endLine;
      if (remaining > 0) {
        result += chalk.gray(`\n${continuationPrefix}↓ ${remaining} more line${remaining > 1 ? 's' : ''}`);
      }
    }

    return result;
  };

  return <Text>{renderValue()}</Text>;
}
