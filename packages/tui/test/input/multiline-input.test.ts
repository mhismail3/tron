/**
 * @fileoverview Tests for MultilineInput handling
 *
 * Tests for multiline input with Shift+Enter support.
 */

import { describe, it, expect } from 'vitest';
import {
  MultilineInput,
  KeyEvent,
  isSubmitKey,
  isNewlineKey,
} from '../../src/input/multiline-input.js';

describe('MultilineInput', () => {
  describe('basic input handling', () => {
    it('should start with empty value', () => {
      const input = new MultilineInput();
      expect(input.getValue()).toBe('');
    });

    it('should accept initial value', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      expect(input.getValue()).toBe('hello');
    });

    it('should set value', () => {
      const input = new MultilineInput();
      input.setValue('new value');
      expect(input.getValue()).toBe('new value');
    });

    it('should clear value', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.clear();
      expect(input.getValue()).toBe('');
    });
  });

  describe('cursor management', () => {
    it('should start cursor at end of initial value', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      expect(input.getCursorPosition()).toBe(5);
    });

    it('should move cursor with arrow keys', () => {
      const input = new MultilineInput({ initialValue: 'hello' });

      input.moveCursor(-1);
      expect(input.getCursorPosition()).toBe(4);

      input.moveCursor(-2);
      expect(input.getCursorPosition()).toBe(2);

      input.moveCursor(1);
      expect(input.getCursorPosition()).toBe(3);
    });

    it('should not move cursor past bounds', () => {
      const input = new MultilineInput({ initialValue: 'hi' });

      input.moveCursor(10);
      expect(input.getCursorPosition()).toBe(2);

      input.moveCursor(-10);
      expect(input.getCursorPosition()).toBe(0);
    });

    it('should move cursor to start and end', () => {
      const input = new MultilineInput({ initialValue: 'hello' });

      input.moveCursorToStart();
      expect(input.getCursorPosition()).toBe(0);

      input.moveCursorToEnd();
      expect(input.getCursorPosition()).toBe(5);
    });
  });

  describe('character insertion', () => {
    it('should insert character at cursor', () => {
      const input = new MultilineInput({ initialValue: 'hllo' });
      input.setCursorPosition(1);
      input.insertChar('e');
      expect(input.getValue()).toBe('hello');
      expect(input.getCursorPosition()).toBe(2);
    });

    it('should insert at end when cursor at end', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.insertChar('!');
      expect(input.getValue()).toBe('hello!');
    });

    it('should insert multiple characters (string)', () => {
      const input = new MultilineInput({ initialValue: 'hd' });
      input.setCursorPosition(1);
      input.insertText('ello worl');
      expect(input.getValue()).toBe('hello world');
    });
  });

  describe('character deletion', () => {
    it('should delete character before cursor (backspace)', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.backspace();
      expect(input.getValue()).toBe('hell');
      expect(input.getCursorPosition()).toBe(4);
    });

    it('should not backspace at start of input', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.setCursorPosition(0);
      input.backspace();
      expect(input.getValue()).toBe('hello');
      expect(input.getCursorPosition()).toBe(0);
    });

    it('should delete character at cursor (delete)', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.setCursorPosition(0);
      input.delete();
      expect(input.getValue()).toBe('ello');
      expect(input.getCursorPosition()).toBe(0);
    });

    it('should not delete at end of input', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.delete();
      expect(input.getValue()).toBe('hello');
    });
  });

  describe('newline handling', () => {
    it('should insert newline', () => {
      const input = new MultilineInput({ initialValue: 'hello' });
      input.insertNewline();
      expect(input.getValue()).toBe('hello\n');
    });

    it('should insert newline in middle of text', () => {
      const input = new MultilineInput({ initialValue: 'helloworld' });
      input.setCursorPosition(5);
      input.insertNewline();
      expect(input.getValue()).toBe('hello\nworld');
    });

    it('should track line count', () => {
      const input = new MultilineInput({ initialValue: 'line1' });
      expect(input.getLineCount()).toBe(1);

      input.insertNewline();
      input.insertText('line2');
      expect(input.getLineCount()).toBe(2);

      input.insertNewline();
      input.insertText('line3');
      expect(input.getLineCount()).toBe(3);
    });

    it('should get current line', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
      input.setCursorPosition(7); // In "line2"
      expect(input.getCurrentLine()).toBe('line2');
    });
  });

  describe('line navigation', () => {
    it('should move to previous line', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2' });
      input.setCursorPosition(8); // In "line2" at position 2

      const moved = input.moveToPreviousLine();

      expect(moved).toBe(true);
      // Should be at same column position or end of previous line
      expect(input.getCursorPosition()).toBeLessThanOrEqual(5);
    });

    it('should not move above first line', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2' });
      input.setCursorPosition(3); // In "line1"

      const moved = input.moveToPreviousLine();

      expect(moved).toBe(false);
    });

    it('should move to next line', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2' });
      input.setCursorPosition(3); // In "line1"

      const moved = input.moveToNextLine();

      expect(moved).toBe(true);
      expect(input.getCursorPosition()).toBeGreaterThan(5);
    });

    it('should not move below last line', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2' });
      input.setCursorPosition(8); // In "line2"

      const moved = input.moveToNextLine();

      expect(moved).toBe(false);
    });
  });

  describe('display helpers', () => {
    it('should get lines array', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
      expect(input.getLines()).toEqual(['line1', 'line2', 'line3']);
    });

    it('should get cursor row and column', () => {
      const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });

      input.setCursorPosition(0);
      expect(input.getCursorRow()).toBe(0);
      expect(input.getCursorColumn()).toBe(0);

      input.setCursorPosition(8); // "li|ne2"
      expect(input.getCursorRow()).toBe(1);
      expect(input.getCursorColumn()).toBe(2);

      input.setCursorPosition(15); // "line3|" end
      expect(input.getCursorRow()).toBe(2);
      expect(input.getCursorColumn()).toBe(3);
    });
  });

  describe('advanced word operations', () => {
    describe('deleteWordBefore (Option+Backspace)', () => {
      it('should delete word before cursor', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.deleteWordBefore();
        expect(input.getValue()).toBe('hello ');
      });

      it('should delete word and preceding whitespace', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.deleteWordBefore();
        expect(input.getValue()).toBe('hello   ');
      });

      it('should do nothing at start of input', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.setCursorPosition(0);
        input.deleteWordBefore();
        expect(input.getValue()).toBe('hello');
      });

      it('should delete word in middle of text', () => {
        const input = new MultilineInput({ initialValue: 'one two three' });
        input.setCursorPosition(7); // After "two"
        input.deleteWordBefore();
        expect(input.getValue()).toBe('one  three');
      });
    });

    describe('deleteWordAfter (Option+Delete)', () => {
      it('should delete word after cursor', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.setCursorPosition(0);
        input.deleteWordAfter();
        expect(input.getValue()).toBe(' world');
      });

      it('should delete just the word (not following whitespace)', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.setCursorPosition(0);
        input.deleteWordAfter();
        // Deletes "hello" only, leaving the whitespace
        expect(input.getValue()).toBe('   world');
      });

      it('should delete whitespace before next word when in whitespace', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.setCursorPosition(5); // After "hello", in whitespace
        input.deleteWordAfter();
        // Deletes "   world" (whitespace + word)
        expect(input.getValue()).toBe('hello');
      });

      it('should do nothing at end of input', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.deleteWordAfter();
        expect(input.getValue()).toBe('hello');
      });
    });

    describe('deleteToLineStart (Cmd+Backspace)', () => {
      it('should delete to start of line', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.deleteToLineStart();
        expect(input.getValue()).toBe('');
      });

      it('should only delete current line in multiline', () => {
        const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
        input.setCursorPosition(11); // End of "line2"
        input.deleteToLineStart();
        expect(input.getValue()).toBe('line1\n\nline3');
      });

      it('should do nothing at start of line', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.setCursorPosition(0);
        input.deleteToLineStart();
        expect(input.getValue()).toBe('hello');
      });
    });

    describe('deleteToLineEnd (Cmd+Delete or Ctrl+K)', () => {
      it('should delete to end of line', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.setCursorPosition(0);
        input.deleteToLineEnd();
        expect(input.getValue()).toBe('');
      });

      it('should only delete current line in multiline', () => {
        const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
        input.setCursorPosition(6); // Start of "line2"
        input.deleteToLineEnd();
        expect(input.getValue()).toBe('line1\n\nline3');
      });

      it('should do nothing at end of input', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.deleteToLineEnd();
        expect(input.getValue()).toBe('hello');
      });
    });

    describe('moveCursorWordLeft (Option+Left)', () => {
      it('should move cursor to start of current word', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.moveCursorWordLeft();
        expect(input.getCursorPosition()).toBe(6); // Start of "world"
      });

      it('should skip whitespace and move to previous word', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.setCursorPosition(8); // In whitespace
        input.moveCursorWordLeft();
        expect(input.getCursorPosition()).toBe(0); // Start of "hello"
      });

      it('should do nothing at start of input', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.setCursorPosition(0);
        input.moveCursorWordLeft();
        expect(input.getCursorPosition()).toBe(0);
      });
    });

    describe('moveCursorWordRight (Option+Right)', () => {
      it('should move cursor to end of current word', () => {
        const input = new MultilineInput({ initialValue: 'hello world' });
        input.setCursorPosition(0);
        input.moveCursorWordRight();
        expect(input.getCursorPosition()).toBe(6); // After "hello "
      });

      it('should skip whitespace and move to start of next word', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.setCursorPosition(5); // After "hello", before whitespace
        input.moveCursorWordRight();
        expect(input.getCursorPosition()).toBe(8); // Start of "world"
      });

      it('should move to end of input when on last word', () => {
        const input = new MultilineInput({ initialValue: 'hello   world' });
        input.setCursorPosition(8); // Start of "world"
        input.moveCursorWordRight();
        expect(input.getCursorPosition()).toBe(13); // End of input
      });

      it('should do nothing at end of input', () => {
        const input = new MultilineInput({ initialValue: 'hello' });
        input.moveCursorWordRight();
        expect(input.getCursorPosition()).toBe(5);
      });
    });

    describe('moveCursorToLineStart/End', () => {
      it('should move to start of current line', () => {
        const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
        input.setCursorPosition(10); // In "line2"
        input.moveCursorToLineStart();
        expect(input.getCursorPosition()).toBe(6); // Start of "line2"
      });

      it('should move to end of current line', () => {
        const input = new MultilineInput({ initialValue: 'line1\nline2\nline3' });
        input.setCursorPosition(6); // Start of "line2"
        input.moveCursorToLineEnd();
        expect(input.getCursorPosition()).toBe(11); // End of "line2"
      });
    });
  });
});

describe('Key event helpers', () => {
  describe('isSubmitKey', () => {
    it('should return true for Enter without shift', () => {
      const event: KeyEvent = { key: 'return', shift: false, ctrl: false, meta: false };
      expect(isSubmitKey(event)).toBe(true);
    });

    it('should return false for Shift+Enter', () => {
      const event: KeyEvent = { key: 'return', shift: true, ctrl: false, meta: false };
      expect(isSubmitKey(event)).toBe(false);
    });

    it('should return false for non-Enter keys', () => {
      const event: KeyEvent = { key: 'a', shift: false, ctrl: false, meta: false };
      expect(isSubmitKey(event)).toBe(false);
    });
  });

  describe('isNewlineKey', () => {
    it('should return true for Shift+Enter', () => {
      const event: KeyEvent = { key: 'return', shift: true, ctrl: false, meta: false };
      expect(isNewlineKey(event)).toBe(true);
    });

    it('should return false for Enter without shift', () => {
      const event: KeyEvent = { key: 'return', shift: false, ctrl: false, meta: false };
      expect(isNewlineKey(event)).toBe(false);
    });

    it('should return false for non-Enter keys with shift', () => {
      const event: KeyEvent = { key: 'a', shift: true, ctrl: false, meta: false };
      expect(isNewlineKey(event)).toBe(false);
    });
  });
});
