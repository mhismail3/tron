/**
 * @fileoverview Input History Hook
 *
 * Manages prompt history navigation with Up/Down arrows.
 * Mirrors TUI behavior from packages/tui/src/app.tsx
 */
import { useState, useCallback } from 'react';

const MAX_HISTORY = 100;

export interface UseInputHistoryOptions {
  /** Maximum number of history entries to keep */
  maxHistory?: number;
}

export interface UseInputHistoryReturn {
  /** Current history entries (oldest first) */
  history: string[];
  /** Current navigation index (-1 = not navigating) */
  historyIndex: number;
  /** Temporarily saved input when navigating */
  temporaryInput: string;
  /** Add an entry to history */
  addToHistory: (entry: string) => void;
  /** Navigate up (older entries) */
  navigateUp: (currentInput: string) => string | null;
  /** Navigate down (newer entries) */
  navigateDown: () => string | null;
  /** Reset navigation state */
  resetNavigation: () => void;
  /** Check if currently navigating history */
  isNavigating: boolean;
}

export function useInputHistory(
  options: UseInputHistoryOptions = {}
): UseInputHistoryReturn {
  const maxHistory = options.maxHistory ?? MAX_HISTORY;

  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [temporaryInput, setTemporaryInput] = useState('');

  const addToHistory = useCallback(
    (entry: string) => {
      const trimmed = entry.trim();
      if (!trimmed) return;

      setHistory((prev) => {
        // Don't add consecutive duplicates
        if (prev.length > 0 && prev[prev.length - 1] === trimmed) {
          return prev;
        }

        const updated = [...prev, trimmed];
        // Trim to max size
        if (updated.length > maxHistory) {
          return updated.slice(-maxHistory);
        }
        return updated;
      });

      // Reset navigation
      setHistoryIndex(-1);
      setTemporaryInput('');
    },
    [maxHistory]
  );

  const navigateUp = useCallback(
    (currentInput: string): string | null => {
      if (history.length === 0) return null;

      if (historyIndex === -1) {
        // Starting navigation - save current input
        setTemporaryInput(currentInput);
        const newIndex = history.length - 1;
        setHistoryIndex(newIndex);
        return history[newIndex] ?? null;
      } else if (historyIndex > 0) {
        // Move to older entry
        const newIndex = historyIndex - 1;
        setHistoryIndex(newIndex);
        return history[newIndex] ?? null;
      }

      // Already at oldest - return current
      return history[historyIndex] ?? null;
    },
    [history, historyIndex]
  );

  const navigateDown = useCallback((): string | null => {
    if (historyIndex === -1) return null;

    if (historyIndex < history.length - 1) {
      // Move to newer entry
      const newIndex = historyIndex + 1;
      setHistoryIndex(newIndex);
      return history[newIndex] ?? null;
    } else {
      // Past end - restore temporary input
      setHistoryIndex(-1);
      return temporaryInput;
    }
  }, [history, historyIndex, temporaryInput]);

  const resetNavigation = useCallback(() => {
    setHistoryIndex(-1);
    setTemporaryInput('');
  }, []);

  return {
    history,
    historyIndex,
    temporaryInput,
    addToHistory,
    navigateUp,
    navigateDown,
    resetNavigation,
    isNavigating: historyIndex !== -1,
  };
}
