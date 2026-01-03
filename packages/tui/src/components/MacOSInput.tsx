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
import { Box, Text, useInput } from 'ink';
import { styled, inkColors, PASTE_THRESHOLD } from '../theme.js';

// =============================================================================
// Types
// =============================================================================

interface UndoState {
  value: string;
  cursorOffset: number;
}

// =============================================================================
// Kitty Keyboard Protocol Helpers
// =============================================================================

/**
 * Parse Kitty keyboard protocol modifier bits
 * Bit 0: Shift, Bit 1: Alt, Bit 2: Ctrl, Bit 3: Super
 */
function parseKittyModifier(modValue: number): { shift: boolean; alt: boolean; ctrl: boolean } {
  const mod = modValue - 1; // Kitty uses 1-indexed modifiers
  return {
    shift: (mod & 1) !== 0,
    alt: (mod & 2) !== 0,
    ctrl: (mod & 4) !== 0,
  };
}

/**
 * Detect Shift+Enter in various terminal formats
 */
function isShiftEnterSequence(input: string): boolean {
  if (!input) return false;
  const normalized = input.startsWith('[') ? `\x1b${input}` : input;

  // Kitty protocol: \x1b[13;2u (Enter with Shift)
  const kittyMatch = normalized.match(/^\x1b\[(\d+);(\d+)u$/);
  if (kittyMatch) {
    const codepoint = Number(kittyMatch[1]);
    const { shift, ctrl } = parseKittyModifier(Number(kittyMatch[2]));
    return codepoint === 13 && shift && !ctrl;
  }

  // modifyOtherKeys format: \x1b[27;2;13~
  const modifyOtherKeysMatch = normalized.match(/^\x1b\[27;(\d+);13~$/);
  if (modifyOtherKeysMatch) {
    const { shift } = parseKittyModifier(Number(modifyOtherKeysMatch[1]));
    return shift;
  }

  // Legacy format: \x1b[13;2~
  const legacyMatch = normalized.match(/^\x1b\[13;(\d+)~$/);
  if (legacyMatch) {
    const { shift } = parseKittyModifier(Number(legacyMatch[1]));
    return shift;
  }

  return false;
}

/**
 * Detect Alt/Option+Enter in various terminal formats
 * Fallback for terminals that don't support Kitty Shift+Enter
 */
function isAltEnterSequence(input: string): boolean {
  if (!input) return false;

  // Standard Alt+Enter: ESC followed by Enter
  if (input === '\x1b\r' || input === '\x1b\n') return true;

  const normalized = input.startsWith('[') ? `\x1b${input}` : input;

  // Kitty protocol: \x1b[13;3u (Enter with Alt)
  // Modifier 3 = (3-1) = 2 = 0b010, bit 1 is alt
  const kittyMatch = normalized.match(/^\x1b\[(\d+);(\d+)u$/);
  if (kittyMatch) {
    const codepoint = Number(kittyMatch[1]);
    const { alt, ctrl } = parseKittyModifier(Number(kittyMatch[2]));
    // Alt+Enter (with or without shift, but not Ctrl)
    return codepoint === 13 && alt && !ctrl;
  }

  return false;
}

/**
 * Detect Ctrl+C in various terminal formats (for exit handling)
 * With Kitty protocol enabled, Ctrl+C may come as an escape sequence
 */
function isCtrlCSequence(input: string): boolean {
  if (!input) return false;

  // Traditional Ctrl+C (ETX character)
  if (input === '\x03') return true;

  const normalized = input.startsWith('[') ? `\x1b${input}` : input;

  // Kitty protocol: \x1b[99;5u (c=99 with Ctrl=modifier 5)
  const kittyMatch = normalized.match(/^\x1b\[(\d+);(\d+)u$/);
  if (kittyMatch) {
    const codepoint = Number(kittyMatch[1]);
    const { ctrl, shift, alt } = parseKittyModifier(Number(kittyMatch[2]));
    // 99 = 'c', 67 = 'C'
    return (codepoint === 99 || codepoint === 67) && ctrl && !shift && !alt;
  }

  return false;
}

export interface MacOSInputProps {
  /** Current input value (may contain paste indicators) */
  value: string;
  /** Callback when value changes */
  onChange: (value: string) => void;
  /** Callback when Enter is pressed (submit) - receives expanded content */
  onSubmit?: (expandedContent?: string) => void;
  /** Placeholder text when empty */
  placeholder?: string;
  /** Whether input is focused */
  focus?: boolean;
  /** Callback for history up (only when cursor at first line) */
  onHistoryUp?: () => void;
  /** Callback for history down (only when cursor at last line) */
  onHistoryDown?: () => void;
  /** Callback when Ctrl+C is pressed (for exit handling) */
  onCtrlC?: () => void;
  /** Maximum visible lines before scrolling (0 = unlimited) */
  maxVisibleLines?: number;
  /** Terminal width for wrapping calculation */
  terminalWidth?: number;
  /** Background color for the input area */
  backgroundColor?: 'gray' | 'black' | 'white' | 'red' | 'green' | 'yellow' | 'blue' | 'magenta' | 'cyan';
  /** Prefix for the first line (e.g., "> " prompt) */
  promptPrefix?: string;
  /** Color for the prompt prefix (supports hex colors) */
  promptColor?: string;
  /** Prefix to add to continuation lines (lines after the first) for alignment */
  continuationPrefix?: string;
  /** Whether input is in processing state (disables editing, shows gray) */
  isProcessing?: boolean;
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
  onCtrlC,
  maxVisibleLines = 20,
  terminalWidth: _terminalWidth = 80,
  promptPrefix = '',
  promptColor = inkColors.promptPrefix,
  continuationPrefix: continuationPrefixProp,
  isProcessing = false,
}: MacOSInputProps): React.ReactElement {
  const continuationPrefix = continuationPrefixProp ?? (promptPrefix ? ' '.repeat(promptPrefix.length) : '');
  const isEditable = focus && !isProcessing;
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
  // Track internal value changes to avoid resetting cursor
  const isInternalChange = useRef(false);
  const pendingCursorOffset = useRef<number | null>(null);
  // Track paste content - maps from display text to actual content
  const pasteContentMap = useRef<Map<string, string>>(new Map());

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

  // Handle cursor positioning when value changes
  // - Internal changes (typing, newlines): use the pending cursor offset
  // - Undo/redo: cursor is already set correctly
  // - External changes (history navigation): reset to end
  useEffect(() => {
    if (isInternalChange.current) {
      // Internal change: apply pending cursor position
      if (pendingCursorOffset.current !== null) {
        setCursorOffset(pendingCursorOffset.current);
        pendingCursorOffset.current = null;
      }
      isInternalChange.current = false;
    } else if (!isUndoRedo.current) {
      // External change (e.g., history navigation): reset to end
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
      // Mark as internal change and store pending cursor position
      // This prevents the useEffect from resetting cursor to end
      isInternalChange.current = true;
      pendingCursorOffset.current = Math.max(0, Math.min(newCursor, newValue.length));
      onChange(newValue);
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

  const insertNewline = useCallback(() => {
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
  }, [hasSelection, deleteSelection, updateValue, value, cursorOffset]);

  /**
   * Format pasted content as a bracketed indicator and store mapping
   */
  const formatPasteIndicator = useCallback((content: string): string => {
    const charCount = content.length;
    const lineCount = content.split('\n').length;

    // Create display text
    let displayText: string;
    if (lineCount > 1) {
      displayText = `⌈text: ${charCount.toLocaleString()} chars, ${lineCount} lines⌋`;
    } else {
      displayText = `⌈text: ${charCount.toLocaleString()} chars⌋`;
    }

    // Store mapping for later expansion
    pasteContentMap.current.set(displayText, content);

    return displayText;
  }, []);

  /**
   * Insert pasted content as a bracketed indicator
   */
  const insertPaste = useCallback((content: string) => {
    const indicator = formatPasteIndicator(content);

    if (hasSelection()) {
      const range = getSelectionRange();
      if (range) {
        const newValue = value.slice(0, range.start) + indicator + value.slice(range.end);
        updateValue(newValue, range.start + indicator.length);
      }
    } else {
      const newValue = value.slice(0, cursorOffset) + indicator + value.slice(cursorOffset);
      updateValue(newValue, cursorOffset + indicator.length);
    }
  }, [formatPasteIndicator, hasSelection, getSelectionRange, updateValue, value, cursorOffset]);

  /**
   * Expand all paste indicators in the value back to their original content
   */
  const expandPasteIndicators = useCallback((text: string): string => {
    let result = text;
    // Find all paste indicators and replace with actual content
    const pastePattern = /⌈text: [\d,]+ chars(?:, \d+ lines)?⌋/g;
    const matches = text.match(pastePattern);

    if (matches) {
      for (const match of matches) {
        const actualContent = pasteContentMap.current.get(match);
        if (actualContent) {
          result = result.replace(match, actualContent);
        }
      }
    }

    return result;
  }, []);

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

  const skipNextInputRef = useRef(false);

  // Use refs to avoid recreating the raw input handler on every render
  const insertNewlineRef = useRef(insertNewline);
  const insertPasteRef = useRef(insertPaste);
  const onCtrlCRef = useRef(onCtrlC);
  const isEditableRef = useRef(isEditable);

  useEffect(() => {
    insertNewlineRef.current = insertNewline;
  }, [insertNewline]);

  useEffect(() => {
    insertPasteRef.current = insertPaste;
  }, [insertPaste]);

  useEffect(() => {
    onCtrlCRef.current = onCtrlC;
  }, [onCtrlC]);

  useEffect(() => {
    isEditableRef.current = isEditable;
  }, [isEditable]);

  // Listen to both 'data' and 'keypress' events for raw terminal sequences
  // 'data' catches raw bytes before readline parsing
  // 'keypress' catches parsed events from readline.emitKeypressEvents()
  useEffect(() => {
    // Handler for raw stdin data (catches Kitty protocol before readline parses it)
    const handleData = (data: Buffer | string) => {
      const str = typeof data === 'string' ? data : data.toString('utf8');

      // Handle Ctrl+C (works even when processing)
      if (isCtrlCSequence(str)) {
        skipNextInputRef.current = true;
        onCtrlCRef.current?.();
        return;
      }

      // Only handle other special keys when editable
      if (!isEditableRef.current) return;

      // Handle Shift+Enter or Alt+Enter from Kitty protocol
      if (isShiftEnterSequence(str) || isAltEnterSequence(str)) {
        skipNextInputRef.current = true;
        insertNewlineRef.current();
        return;
      }

      // Detect paste: multiple printable characters arriving at once
      // Filter out escape sequences and control characters
      const isPrintable = str.length > PASTE_THRESHOLD &&
        !str.startsWith('\x1b') &&
        !/^[\x00-\x1f]+$/.test(str);

      if (isPrintable) {
        skipNextInputRef.current = true;
        insertPasteRef.current(str);
        return;
      }
    };

    // Handler for parsed keypress events (backup for terminals that understand Shift+Enter)
    const handleKeypress = (char: string | undefined, key: { sequence?: string; name?: string; shift?: boolean; meta?: boolean } | undefined) => {
      // Skip if already handled by data handler
      if (skipNextInputRef.current) return;

      const seq = key?.sequence || char || '';

      // Handle Ctrl+C
      if (isCtrlCSequence(seq) || (char === '\x03')) {
        skipNextInputRef.current = true;
        onCtrlCRef.current?.();
        return;
      }

      // Only handle other special keys when editable
      if (!isEditableRef.current) return;

      // Handle Shift+Enter or Alt+Enter
      const isShiftEnterKey = key?.name === 'return' && key?.shift;
      const isAltEnterKey = key?.name === 'return' && key?.meta;
      if (isShiftEnterSequence(seq) || isAltEnterSequence(seq) || isShiftEnterKey || isAltEnterKey) {
        skipNextInputRef.current = true;
        insertNewlineRef.current();
        return;
      }
    };

    process.stdin.on('data', handleData);
    process.stdin.on('keypress', handleKeypress);
    return () => {
      process.stdin.removeListener('data', handleData);
      process.stdin.removeListener('keypress', handleKeypress);
    };
  }, []);

  useInput(
    (input, key) => {
      if (skipNextInputRef.current) {
        skipNextInputRef.current = false;
        return;
      }

      // Ctrl+C - call callback for exit
      if (key.ctrl && input === 'c') {
        onCtrlC?.();
        return;
      }

      // Tab - let it propagate
      if (key.tab) {
        return;
      }

      // Shift+Enter or Alt+Enter inserts a newline
      // Alt+Enter is the fallback for terminals that don't support Kitty protocol
      const isShiftEnter = (key.return && key.shift) || isShiftEnterSequence(input);
      const isAltEnter = (key.return && key.meta) || isAltEnterSequence(input);
      if (isShiftEnter || isAltEnter) {
        insertNewline();
        return;
      }

      // Enter - submit (without shift)
      if (key.return || input === '\r' || input === '\n') {
        // Expand paste indicators before submitting
        const expandedContent = expandPasteIndicators(value);
        onSubmit?.(expandedContent);
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
    { isActive: isEditable }
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

  /**
   * Render a single line with cursor and selection highlighting
   */
  const renderLine = (
    line: string,
    lineStartPos: number,
    _lineIdx: number,
    _totalLines: number,
    range: { start: number; end: number } | null
  ): string => {
    let renderedLine = '';
    let inPasteIndicator = false;

    for (let i = 0; i < line.length; i++) {
      const globalPos = lineStartPos + i;
      const char = line[i] ?? '';
      const isSelected = range && globalPos >= range.start && globalPos < range.end;
      const isCursor = globalPos === cursorOffset;

      // Track if we're in a paste indicator
      if (char === '⌈') inPasteIndicator = true;

      if (isSelected) {
        renderedLine += styled.selection(char);
      } else if (isCursor) {
        renderedLine += styled.cursor(char);
      } else if (inPasteIndicator) {
        // Style paste indicators with the paste color
        renderedLine += styled.pasteIndicator(char);
      } else {
        renderedLine += char;
      }

      if (char === '⌋') inPasteIndicator = false;
    }

    // Check if cursor is at end of this line
    const endOfLinePos = lineStartPos + line.length;
    if (cursorOffset === endOfLinePos) {
      // Cursor at end of line (either before newline or at end of value)
      renderedLine += styled.cursor(' ');
    }

    return renderedLine;
  };

  /**
   * Build the render data for multiline display
   */
  interface RenderLine {
    content: string;
    isIndicator: boolean; // true for scroll indicators
    isFirstContentLine: boolean; // true for the first actual content line
  }

  const buildRenderData = (): RenderLine[] => {
    if (!focus) {
      const content = value || styled.placeholder(placeholder);
      // For unfocused multiline, show all lines
      if (value.includes('\n')) {
        return value.split('\n').map((line, idx) => ({
          content: line || ' ',
          isIndicator: false,
          isFirstContentLine: idx === 0,
        }));
      }
      return [{ content, isIndicator: false, isFirstContentLine: true }];
    }

    if (value.length === 0) {
      const content = placeholder
        ? styled.cursor(placeholder[0] ?? ' ') + styled.placeholder(placeholder.slice(1))
        : styled.cursor(' ');
      return [{ content, isIndicator: false, isFirstContentLine: true }];
    }

    const range = getSelectionRange();
    const lines = getLines();
    const totalLines = lines.length;

    // Determine visible lines
    const startLine = maxVisibleLines > 0 ? scrollOffset : 0;
    const endLine = maxVisibleLines > 0 ? Math.min(startLine + maxVisibleLines, totalLines) : totalLines;

    // Calculate character position at start of visible region
    let charOffset = 0;
    for (let i = 0; i < startLine; i++) {
      charOffset += (lines[i]?.length ?? 0) + 1;
    }

    const renderData: RenderLine[] = [];
    let currentCharPos = charOffset;
    let isFirstContent = true;

    // Add scroll-up indicator if needed
    if (maxVisibleLines > 0 && scrollOffset > 0) {
      renderData.push({
        content: styled.dim(`↑ ${scrollOffset} more line${scrollOffset > 1 ? 's' : ''}`),
        isIndicator: true,
        isFirstContentLine: false,
      });
    }

    // Render each visible line
    for (let lineIdx = startLine; lineIdx < endLine; lineIdx++) {
      const line = lines[lineIdx] ?? '';
      const rendered = renderLine(line, currentCharPos, lineIdx, totalLines, range);
      renderData.push({
        content: rendered || ' ', // Ensure empty lines still render
        isIndicator: false,
        isFirstContentLine: isFirstContent,
      });
      isFirstContent = false;
      currentCharPos += line.length + 1; // +1 for newline
    }

    // Add scroll-down indicator if needed
    if (maxVisibleLines > 0 && totalLines > maxVisibleLines) {
      const remaining = totalLines - endLine;
      if (remaining > 0) {
        renderData.push({
          content: styled.dim(`↓ ${remaining} more line${remaining > 1 ? 's' : ''}`),
          isIndicator: true,
          isFirstContentLine: false,
        });
      }
    }

    return renderData;
  };

  const prefixColor = isProcessing ? inkColors.dim : promptColor;
  const renderPrefix = (isFirstContentLine: boolean): React.ReactElement | null => {
    const prefix = isFirstContentLine ? promptPrefix : continuationPrefix;
    if (!prefix) return null;
    if (isFirstContentLine) {
      return (
        <Text color={prefixColor} bold>
          {prefix}
        </Text>
      );
    }
    return <Text>{prefix}</Text>;
  };

  if (isProcessing) {
    const displayValue = value.length > 0 ? value : 'Processing...';
    const lines = displayValue.split('\n');
    return (
      <Box flexDirection="column">
        {lines.map((line, idx) => (
          <Box key={idx} flexDirection="row">
            {renderPrefix(idx === 0)}
            <Text color={inkColors.dim}>{line || ' '}</Text>
          </Box>
        ))}
      </Box>
    );
  }

  const renderData = buildRenderData();

  // Return Box with separate Text elements for each line
  // This ensures proper Ink flex layout instead of relying on \n characters
  return (
    <Box flexDirection="column">
      {renderData.map((line, idx) => (
        <Box key={idx} flexDirection="row">
          {/* First content line gets the prompt prefix; subsequent lines/indicators get continuation prefix */}
          {renderPrefix(line.isFirstContentLine)}
          <Text>{line.content}</Text>
        </Box>
      ))}
    </Box>
  );
}
