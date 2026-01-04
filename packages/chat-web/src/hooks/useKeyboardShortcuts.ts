/**
 * @fileoverview Global Keyboard Shortcuts Hook
 *
 * Provides global keyboard shortcuts for the chat application.
 * Shortcuts are active when not focused on an input element.
 */
import { useEffect, useCallback } from 'react';

export interface KeyboardShortcuts {
  /** Open command palette (Ctrl+K or Ctrl+/) */
  onOpenCommandPalette?: () => void;
  /** Close menu / interrupt processing (Escape) */
  onEscape?: () => void;
  /** Focus input (/ when not in input) */
  onFocusInput?: () => void;
  /** New session (Ctrl+N) */
  onNewSession?: () => void;
}

export interface UseKeyboardShortcutsOptions {
  /** Whether shortcuts are enabled */
  enabled?: boolean;
  /** Shortcut handlers */
  shortcuts: KeyboardShortcuts;
}

function isInputElement(element: Element | null): boolean {
  if (!element) return false;
  const tagName = element.tagName.toLowerCase();
  return (
    tagName === 'input' ||
    tagName === 'textarea' ||
    (element as HTMLElement).isContentEditable
  );
}

export function useKeyboardShortcuts({
  enabled = true,
  shortcuts,
}: UseKeyboardShortcutsOptions): void {
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!enabled) return;

      const isMac = navigator.platform.toLowerCase().includes('mac');
      const cmdOrCtrl = isMac ? e.metaKey : e.ctrlKey;
      const inInput = isInputElement(document.activeElement);

      // Ctrl+K or Ctrl+/ - Open command palette
      if (cmdOrCtrl && (e.key === 'k' || e.key === '/')) {
        e.preventDefault();
        shortcuts.onOpenCommandPalette?.();
        return;
      }

      // Ctrl+N - New session
      if (cmdOrCtrl && e.key === 'n') {
        e.preventDefault();
        shortcuts.onNewSession?.();
        return;
      }

      // Escape - Close menu / interrupt
      if (e.key === 'Escape') {
        shortcuts.onEscape?.();
        return;
      }

      // / - Focus input (only when not in input and not with modifiers)
      if (e.key === '/' && !inInput && !cmdOrCtrl && !e.altKey && !e.shiftKey) {
        e.preventDefault();
        shortcuts.onFocusInput?.();
        return;
      }
    },
    [enabled, shortcuts]
  );

  useEffect(() => {
    if (!enabled) return;

    window.addEventListener('keydown', handleKeyDown);
    return () => {
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [enabled, handleKeyDown]);
}
