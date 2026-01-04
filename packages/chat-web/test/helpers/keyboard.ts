/**
 * @fileoverview Keyboard Test Helpers
 *
 * Provides utilities for simulating keyboard events in tests.
 */

import { fireEvent } from '@testing-library/react';

// =============================================================================
// Types
// =============================================================================

export interface KeyEventOptions {
  ctrlKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

// =============================================================================
// Key Press Helpers
// =============================================================================

/**
 * Press a key on an element
 */
export function pressKey(
  element: Element,
  key: string,
  options: KeyEventOptions = {},
): void {
  const eventOptions = {
    key,
    code: getKeyCode(key),
    bubbles: true,
    cancelable: true,
    ...options,
  };

  fireEvent.keyDown(element, eventOptions);
  fireEvent.keyUp(element, eventOptions);
}

/**
 * Press Enter key
 */
export function pressEnter(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'Enter', options);
}

/**
 * Press Escape key
 */
export function pressEscape(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'Escape', options);
}

/**
 * Press Arrow Up key
 */
export function pressArrowUp(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'ArrowUp', options);
}

/**
 * Press Arrow Down key
 */
export function pressArrowDown(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'ArrowDown', options);
}

/**
 * Press Tab key
 */
export function pressTab(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'Tab', options);
}

/**
 * Press Backspace key
 */
export function pressBackspace(element: Element, options: KeyEventOptions = {}): void {
  pressKey(element, 'Backspace', options);
}

// =============================================================================
// Key Combinations
// =============================================================================

/**
 * Press Ctrl+Enter
 */
export function pressCtrlEnter(element: Element): void {
  pressEnter(element, { ctrlKey: true });
}

/**
 * Press Shift+Enter
 */
export function pressShiftEnter(element: Element): void {
  pressEnter(element, { shiftKey: true });
}

/**
 * Press Cmd/Ctrl+K (command palette shortcut)
 */
export function pressCommandK(element: Element, isMac = false): void {
  if (isMac) {
    pressKey(element, 'k', { metaKey: true });
  } else {
    pressKey(element, 'k', { ctrlKey: true });
  }
}

/**
 * Press Ctrl+/ (alternative command palette)
 */
export function pressCtrlSlash(element: Element): void {
  pressKey(element, '/', { ctrlKey: true });
}

/**
 * Press Ctrl+C (abort/copy)
 */
export function pressCtrlC(element: Element): void {
  pressKey(element, 'c', { ctrlKey: true });
}

// =============================================================================
// Input Simulation
// =============================================================================

/**
 * Type text into an input element
 */
export function typeText(element: Element, text: string): void {
  fireEvent.change(element, { target: { value: text } });
}

/**
 * Type text character by character (for keystroke simulation)
 */
export function typeTextSlowly(
  element: Element,
  text: string,
  getValue: () => string,
): void {
  for (const char of text) {
    const currentValue = getValue();
    const newValue = currentValue + char;

    fireEvent.keyDown(element, { key: char, code: getKeyCode(char) });
    fireEvent.change(element, { target: { value: newValue } });
    fireEvent.keyUp(element, { key: char, code: getKeyCode(char) });
  }
}

/**
 * Clear an input element
 */
export function clearInput(element: Element): void {
  fireEvent.change(element, { target: { value: '' } });
}

// =============================================================================
// Focus Helpers
// =============================================================================

/**
 * Focus an element
 */
export function focusElement(element: Element): void {
  fireEvent.focus(element);
}

/**
 * Blur an element
 */
export function blurElement(element: Element): void {
  fireEvent.blur(element);
}

// =============================================================================
// Utilities
// =============================================================================

/**
 * Get key code from key name
 */
function getKeyCode(key: string): string {
  const keyCodeMap: Record<string, string> = {
    Enter: 'Enter',
    Escape: 'Escape',
    ArrowUp: 'ArrowUp',
    ArrowDown: 'ArrowDown',
    ArrowLeft: 'ArrowLeft',
    ArrowRight: 'ArrowRight',
    Tab: 'Tab',
    Backspace: 'Backspace',
    Delete: 'Delete',
    Home: 'Home',
    End: 'End',
    PageUp: 'PageUp',
    PageDown: 'PageDown',
    ' ': 'Space',
  };

  // Single character
  if (key.length === 1) {
    const code = key.toUpperCase().charCodeAt(0);
    if (code >= 65 && code <= 90) {
      return `Key${key.toUpperCase()}`;
    }
    if (code >= 48 && code <= 57) {
      return `Digit${key}`;
    }
    return keyCodeMap[key] ?? key;
  }

  return keyCodeMap[key] ?? key;
}

/**
 * Create a keyboard event
 */
export function createKeyboardEvent(
  type: 'keydown' | 'keyup' | 'keypress',
  key: string,
  options: KeyEventOptions = {},
): KeyboardEvent {
  return new KeyboardEvent(type, {
    key,
    code: getKeyCode(key),
    bubbles: true,
    cancelable: true,
    ...options,
  });
}
