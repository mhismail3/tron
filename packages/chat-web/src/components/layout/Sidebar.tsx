/**
 * @fileoverview Sidebar Component
 *
 * Session list sidebar with new session button and session management.
 */

import { useState, useCallback, type ReactNode } from 'react';
import './Sidebar.css';
import mooseIcon from '../../assets/moose-icon.png';
import tronLogo from '../../assets/tron-logo.png';

// =============================================================================
// Types
// =============================================================================

export interface SessionSummary {
  sessionId: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
}

export interface SidebarProps {
  /** List of sessions */
  sessions?: SessionSummary[];
  /** Currently active session ID */
  activeSessionId?: string;
  /** Whether sidebar is collapsed */
  collapsed?: boolean;
  /** Callback when new session requested */
  onNewSession?: () => void;
  /** Callback when session selected */
  onSessionSelect?: (sessionId: string) => void;
  /** Callback when session deleted */
  onSessionDelete?: (sessionId: string) => void;
  /** Header content override */
  header?: ReactNode;
}

// =============================================================================
// Helper Components
// =============================================================================

interface SessionItemProps {
  session: SessionSummary;
  isActive: boolean;
  collapsed: boolean;
  onSelect: () => void;
  onDelete: () => void;
}

function SessionItem({
  session,
  isActive,
  collapsed,
  onSelect,
  onDelete,
}: SessionItemProps) {
  const [isHovered, setIsHovered] = useState(false);

  // Extract project name from path
  const projectName = session.workingDirectory.split('/').pop() || 'Unknown';

  const itemClasses = ['session-item', isActive && 'active']
    .filter(Boolean)
    .join(' ');

  const handleDeleteClick = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      onDelete();
    },
    [onDelete],
  );

  return (
    <li
      className={itemClasses}
      onClick={onSelect}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      role="option"
      aria-selected={isActive}
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onSelect();
        }
      }}
    >
      <span className="session-icon">◉</span>

      <div className={`session-details ${collapsed ? 'sr-only' : ''}`}>
        <span className="session-name">{projectName}</span>
        <span className="session-meta">{session.messageCount} messages</span>
      </div>

      {isHovered && !collapsed && (
        <button
          className="session-delete"
          onClick={handleDeleteClick}
          aria-label="Delete session"
          type="button"
        >
          ✕
        </button>
      )}
    </li>
  );
}

// =============================================================================
// Main Component
// =============================================================================

export function Sidebar({
  sessions = [],
  activeSessionId,
  collapsed = false,
  onNewSession,
  onSessionSelect,
  onSessionDelete,
  header,
}: SidebarProps) {
  const sidebarClasses = ['sidebar', collapsed && 'collapsed']
    .filter(Boolean)
    .join(' ');

  return (
    <nav className={sidebarClasses} role="navigation" aria-label="Sessions">
      {/* Header */}
      <div className="sidebar-header">
        {header || (
          <>
            <span className="sidebar-title">Sessions</span>
            <button
              className="new-session-btn"
              onClick={onNewSession}
              aria-label="New session"
              type="button"
            >
              <span className="btn-icon">+</span>
              {!collapsed && <span className="btn-text">New</span>}
            </button>
          </>
        )}
      </div>

      {/* Session List */}
      <ul className="session-list" role="listbox" aria-label="Sessions">
        {sessions.length === 0 ? (
          <li className="session-empty">
            <span className="empty-icon">◌</span>
            {!collapsed && <span className="empty-text">No sessions</span>}
          </li>
        ) : (
          sessions.map((session) => (
            <SessionItem
              key={session.sessionId}
              session={session}
              isActive={session.sessionId === activeSessionId}
              collapsed={collapsed}
              onSelect={() => onSessionSelect?.(session.sessionId)}
              onDelete={() => onSessionDelete?.(session.sessionId)}
            />
          ))
        )}
      </ul>

      {/* Footer */}
      <div className="sidebar-footer">
        {!collapsed && (
          <div className="footer-brand">
            <img src={mooseIcon} alt="" className="footer-icon" />
            <img src={tronLogo} alt="Tron" className="footer-logo" />
          </div>
        )}
      </div>
    </nav>
  );
}
