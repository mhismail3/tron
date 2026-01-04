/**
 * @fileoverview AppShell Component
 *
 * Main layout shell with CSS Grid for sidebar and content areas.
 * Supports responsive behavior with mobile drawer.
 */

import { useState, useCallback, type ReactNode } from 'react';
import './AppShell.css';

// =============================================================================
// Types
// =============================================================================

export interface AppShellProps {
  /** Sidebar content */
  sidebar: ReactNode;
  /** Main content area */
  main: ReactNode;
  /** Whether sidebar is open (controlled) */
  sidebarOpen?: boolean;
  /** Callback when sidebar toggle requested */
  onSidebarToggle?: (open: boolean) => void;
  /** Mobile mode flag */
  isMobile?: boolean;
}

// =============================================================================
// Component
// =============================================================================

export function AppShell({
  sidebar,
  main,
  sidebarOpen: controlledOpen,
  onSidebarToggle,
  isMobile = false,
}: AppShellProps) {
  // Internal state for uncontrolled mode
  const [internalOpen, setInternalOpen] = useState(true);

  // Use controlled or internal state
  const isOpen = controlledOpen ?? internalOpen;

  const handleToggle = useCallback(() => {
    const newState = !isOpen;
    if (onSidebarToggle) {
      onSidebarToggle(newState);
    } else {
      setInternalOpen(newState);
    }
  }, [isOpen, onSidebarToggle]);

  const handleOverlayClick = useCallback(() => {
    if (onSidebarToggle) {
      onSidebarToggle(false);
    } else {
      setInternalOpen(false);
    }
  }, [onSidebarToggle]);

  const shellClasses = ['app-shell', isMobile && 'mobile']
    .filter(Boolean)
    .join(' ');

  const asideClasses = ['app-shell-sidebar', !isOpen && 'collapsed']
    .filter(Boolean)
    .join(' ');

  return (
    <div className={shellClasses}>
      {/* Mobile overlay */}
      {isMobile && isOpen && (
        <div
          className="sidebar-overlay"
          data-testid="sidebar-overlay"
          onClick={handleOverlayClick}
          aria-hidden="true"
        />
      )}

      {/* Sidebar toggle button */}
      <button
        className="sidebar-toggle"
        onClick={handleToggle}
        aria-label="Toggle sidebar"
        aria-expanded={isOpen}
        type="button"
      >
        <span className="toggle-icon">{isOpen ? '◂' : '▸'}</span>
      </button>

      {/* Sidebar */}
      <aside className={asideClasses} aria-label="Session sidebar">
        {sidebar}
      </aside>

      {/* Main content */}
      <main className="app-shell-main">{main}</main>
    </div>
  );
}
