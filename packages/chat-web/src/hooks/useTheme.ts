/**
 * @fileoverview Theme hook for managing light/dark mode
 *
 * Handles theme state, persistence, and system preference detection.
 * Applies theme via data-theme attribute on document root.
 */

import { useState, useEffect, useCallback } from 'react';

export type Theme = 'light' | 'dark' | 'system';
export type ResolvedTheme = 'light' | 'dark';

const THEME_STORAGE_KEY = 'tron-chat-theme';

/**
 * Get the system's preferred color scheme
 */
function getSystemTheme(): ResolvedTheme {
  if (typeof window === 'undefined') return 'dark';
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
}

/**
 * Get stored theme preference from localStorage
 */
function getStoredTheme(): Theme {
  if (typeof window === 'undefined') return 'system';
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored === 'light' || stored === 'dark' || stored === 'system') {
      return stored;
    }
  } catch {
    // localStorage might be unavailable
  }
  return 'system';
}

/**
 * Store theme preference to localStorage
 */
function storeTheme(theme: Theme): void {
  if (typeof window === 'undefined') return;
  try {
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch {
    // localStorage might be unavailable
  }
}

/**
 * Apply theme to document root
 */
function applyTheme(resolvedTheme: ResolvedTheme, isExplicit: boolean): void {
  if (typeof document === 'undefined') return;

  const root = document.documentElement;

  // Set data-theme attribute (used by CSS)
  // When explicit (user chose), always set the attribute to override media queries
  // When system (auto), remove attribute to let media queries handle it
  if (isExplicit) {
    root.setAttribute('data-theme', resolvedTheme);
  } else {
    root.removeAttribute('data-theme');
  }
}

/**
 * Hook for managing theme state
 */
export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(() => getStoredTheme());
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(() => {
    const stored = getStoredTheme();
    return stored === 'system' ? getSystemTheme() : stored;
  });

  // Apply theme on mount and changes
  useEffect(() => {
    const resolved = theme === 'system' ? getSystemTheme() : theme;
    const isExplicit = theme !== 'system';
    setResolvedTheme(resolved);
    applyTheme(resolved, isExplicit);
  }, [theme]);

  // Listen for system preference changes
  useEffect(() => {
    if (theme !== 'system') return;

    const mediaQuery = window.matchMedia('(prefers-color-scheme: light)');

    const handleChange = (e: MediaQueryListEvent) => {
      const newResolved = e.matches ? 'light' : 'dark';
      setResolvedTheme(newResolved);
      applyTheme(newResolved, false); // system preference, not explicit
    };

    mediaQuery.addEventListener('change', handleChange);
    return () => mediaQuery.removeEventListener('change', handleChange);
  }, [theme]);

  // Initialize on mount (handle hydration)
  useEffect(() => {
    // Remove no-transitions class after initial render
    const timeout = setTimeout(() => {
      document.documentElement.classList.remove('no-transitions');
    }, 100);

    return () => clearTimeout(timeout);
  }, []);

  const setTheme = useCallback((newTheme: Theme) => {
    setThemeState(newTheme);
    storeTheme(newTheme);
  }, []);

  const toggleTheme = useCallback(() => {
    setThemeState((current) => {
      const next = current === 'dark' ? 'light' : current === 'light' ? 'system' : 'dark';
      storeTheme(next);
      return next;
    });
  }, []);

  const cycleTheme = useCallback(() => {
    setThemeState((current) => {
      // Cycle: dark -> light -> system -> dark
      const next = current === 'dark' ? 'light' : current === 'light' ? 'system' : 'dark';
      storeTheme(next);
      return next;
    });
  }, []);

  return {
    theme,
    resolvedTheme,
    setTheme,
    toggleTheme,
    cycleTheme,
    isDark: resolvedTheme === 'dark',
    isLight: resolvedTheme === 'light',
  };
}
