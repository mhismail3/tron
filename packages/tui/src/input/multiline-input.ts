/**
 * @fileoverview Multiline Input Manager
 *
 * Handles multiline text input with cursor management.
 * Supports Shift+Enter for newlines.
 */

export interface MultilineInputOptions {
  /** Initial value */
  initialValue?: string;
}

export interface KeyEvent {
  key: string;
  shift: boolean;
  ctrl: boolean;
  meta: boolean;
}

/**
 * Check if key event is a submit (Enter without shift).
 */
export function isSubmitKey(event: KeyEvent): boolean {
  return event.key === 'return' && !event.shift;
}

/**
 * Check if key event is a newline (Shift+Enter).
 */
export function isNewlineKey(event: KeyEvent): boolean {
  return event.key === 'return' && event.shift;
}

/**
 * Multiline input manager with cursor support.
 */
export class MultilineInput {
  private value: string;
  private cursor: number;

  constructor(options: MultilineInputOptions = {}) {
    this.value = options.initialValue ?? '';
    this.cursor = this.value.length;
  }

  /**
   * Get current value.
   */
  getValue(): string {
    return this.value;
  }

  /**
   * Set value and move cursor to end.
   */
  setValue(value: string): void {
    this.value = value;
    this.cursor = value.length;
  }

  /**
   * Clear input.
   */
  clear(): void {
    this.value = '';
    this.cursor = 0;
  }

  /**
   * Get cursor position.
   */
  getCursorPosition(): number {
    return this.cursor;
  }

  /**
   * Set cursor position, clamped to valid range.
   */
  setCursorPosition(position: number): void {
    this.cursor = Math.max(0, Math.min(position, this.value.length));
  }

  /**
   * Move cursor by offset, clamped to valid range.
   */
  moveCursor(offset: number): void {
    this.setCursorPosition(this.cursor + offset);
  }

  /**
   * Move cursor to start.
   */
  moveCursorToStart(): void {
    this.cursor = 0;
  }

  /**
   * Move cursor to end.
   */
  moveCursorToEnd(): void {
    this.cursor = this.value.length;
  }

  /**
   * Insert a single character at cursor.
   */
  insertChar(char: string): void {
    this.insertText(char);
  }

  /**
   * Insert text at cursor.
   */
  insertText(text: string): void {
    this.value = this.value.slice(0, this.cursor) + text + this.value.slice(this.cursor);
    this.cursor += text.length;
  }

  /**
   * Insert newline at cursor.
   */
  insertNewline(): void {
    this.insertChar('\n');
  }

  /**
   * Delete character before cursor (backspace).
   */
  backspace(): void {
    if (this.cursor === 0) {
      return;
    }
    this.value = this.value.slice(0, this.cursor - 1) + this.value.slice(this.cursor);
    this.cursor--;
  }

  /**
   * Delete character at cursor.
   */
  delete(): void {
    if (this.cursor === this.value.length) {
      return;
    }
    this.value = this.value.slice(0, this.cursor) + this.value.slice(this.cursor + 1);
  }

  /**
   * Get number of lines.
   */
  getLineCount(): number {
    return this.getLines().length;
  }

  /**
   * Get lines as array.
   */
  getLines(): string[] {
    return this.value.split('\n');
  }

  /**
   * Get the current line (where cursor is).
   */
  getCurrentLine(): string {
    const lines = this.getLines();
    const row = this.getCursorRow();
    return lines[row] ?? '';
  }

  /**
   * Get cursor row (0-indexed line number).
   */
  getCursorRow(): number {
    const beforeCursor = this.value.slice(0, this.cursor);
    return (beforeCursor.match(/\n/g) || []).length;
  }

  /**
   * Get cursor column (position within current line).
   */
  getCursorColumn(): number {
    const beforeCursor = this.value.slice(0, this.cursor);
    const lastNewline = beforeCursor.lastIndexOf('\n');
    return lastNewline === -1 ? this.cursor : this.cursor - lastNewline - 1;
  }

  /**
   * Move to previous line (up arrow).
   * Tries to maintain column position.
   * Returns true if moved, false if already at first line.
   */
  moveToPreviousLine(): boolean {
    const row = this.getCursorRow();
    if (row === 0) {
      return false;
    }

    const column = this.getCursorColumn();
    const lines = this.getLines();
    const prevLine = lines[row - 1] ?? '';

    // Calculate new cursor position
    let newPosition = 0;
    for (let i = 0; i < row - 1; i++) {
      newPosition += (lines[i] ?? '').length + 1; // +1 for newline
    }
    newPosition += Math.min(column, prevLine.length);

    this.cursor = newPosition;
    return true;
  }

  /**
   * Move to next line (down arrow).
   * Tries to maintain column position.
   * Returns true if moved, false if already at last line.
   */
  moveToNextLine(): boolean {
    const row = this.getCursorRow();
    const lines = this.getLines();

    if (row >= lines.length - 1) {
      return false;
    }

    const column = this.getCursorColumn();
    const nextLine = lines[row + 1] ?? '';

    // Calculate new cursor position
    let newPosition = 0;
    for (let i = 0; i <= row; i++) {
      newPosition += (lines[i] ?? '').length + 1; // +1 for newline
    }
    newPosition += Math.min(column, nextLine.length);

    this.cursor = newPosition;
    return true;
  }
}
