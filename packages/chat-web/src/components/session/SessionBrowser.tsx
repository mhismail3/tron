/**
 * @fileoverview Session Browser Component
 *
 * A dialog that shows all past sessions and allows users to:
 * - View session list with metadata
 * - Search and filter sessions
 * - Select a session to view its history tree
 * - Fork from any event in any past session
 */

import { useState, useCallback, useMemo, useEffect } from 'react';
import { SessionTree } from '../tree/index.js';
import { useSessionHistory } from '../../hooks/index.js';
import type { SessionSummary } from '../../store/types.js';
import './SessionBrowser.css';

// =============================================================================
// Types
// =============================================================================

export interface SessionBrowserProps {
  /** Whether the browser is open */
  isOpen: boolean;
  /** Close callback */
  onClose: () => void;
  /** List of sessions to display */
  sessions: SessionSummary[];
  /** RPC call function */
  rpcCall: <T>(method: string, params?: unknown) => Promise<T>;
  /** Callback when a session is selected */
  onSelectSession: (sessionId: string) => void;
  /** Callback when user wants to fork from an event */
  onForkFromEvent: (sessionId: string, eventId: string) => void;
  /** Currently selected session ID */
  selectedSessionId?: string;
  /** Whether to group sessions by working directory */
  groupByDirectory?: boolean;
  /** Current session ID (to exclude from list) */
  currentSessionId?: string;
}

interface ForkConfirmation {
  sessionId: string;
  eventId: string;
  eventSummary: string;
}

// =============================================================================
// Icons
// =============================================================================

function CloseIcon() {
  return (
    <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
      />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
      />
    </svg>
  );
}

// =============================================================================
// Session Item Component
// =============================================================================

interface SessionItemProps {
  session: SessionSummary;
  isSelected: boolean;
  onClick: () => void;
}

function SessionItem({ session, isSelected, onClick }: SessionItemProps) {
  const formatDate = (dateStr: string) => {
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffDays = Math.floor(diffMs / 86400000);

    if (diffDays === 0) return 'Today';
    if (diffDays === 1) return 'Yesterday';
    if (diffDays < 7) return `${diffDays} days ago`;
    return date.toLocaleDateString();
  };

  const getModelDisplay = (model: string | undefined) => {
    if (!model) return 'Unknown';
    if (model.includes('opus')) return 'Opus';
    if (model.includes('sonnet')) return 'Sonnet';
    if (model.includes('haiku')) return 'Haiku';
    return model.split('-')[0] || model;
  };

  return (
    <li
      className={`session-item ${isSelected ? 'selected' : ''}`}
      onClick={onClick}
      role="listitem"
      aria-selected={isSelected}
    >
      <div className="session-item-header">
        <span className="session-title">{session.title || 'Untitled Session'}</span>
        <span className="session-model">{getModelDisplay(session.model)}</span>
      </div>
      <div className="session-item-meta">
        <span className="session-messages">{session.messageCount ?? 0} messages</span>
        <span className="session-date">{formatDate(session.lastActivity)}</span>
      </div>
    </li>
  );
}

// =============================================================================
// Main Component
// =============================================================================

export function SessionBrowser({
  isOpen,
  onClose,
  sessions,
  rpcCall,
  onSelectSession,
  onForkFromEvent,
  selectedSessionId,
  groupByDirectory = false,
  currentSessionId,
}: SessionBrowserProps) {
  const [searchQuery, setSearchQuery] = useState('');
  const [internalSelectedId, setInternalSelectedId] = useState<string | null>(
    selectedSessionId ?? null
  );
  const [forkConfirmation, setForkConfirmation] = useState<ForkConfirmation | null>(null);

  // Use the selected session ID from props or internal state
  const activeSessionId = selectedSessionId ?? internalSelectedId;

  // Load history for selected session
  const sessionHistory = useSessionHistory({
    sessionId: activeSessionId,
    rpcCall,
    includeBranches: true,
  });

  // Update internal state when prop changes
  useEffect(() => {
    if (selectedSessionId) {
      setInternalSelectedId(selectedSessionId);
    }
  }, [selectedSessionId]);

  // Filter sessions
  const filteredSessions = useMemo(() => {
    let result = sessions.filter((s) => s.id !== currentSessionId);

    if (searchQuery.trim()) {
      const query = searchQuery.toLowerCase();
      result = result.filter(
        (s) =>
          (s.title?.toLowerCase().includes(query) ?? false) ||
          (s.workingDirectory?.toLowerCase().includes(query) ?? false)
      );
    }

    // Sort by last activity (most recent first)
    result.sort(
      (a, b) =>
        new Date(b.lastActivity).getTime() - new Date(a.lastActivity).getTime()
    );

    return result;
  }, [sessions, searchQuery, currentSessionId]);

  // Group by directory if enabled
  const groupedSessions = useMemo(() => {
    if (!groupByDirectory) return null;

    const groups = new Map<string, SessionSummary[]>();
    for (const session of filteredSessions) {
      const dir = session.workingDirectory ?? 'Unknown';
      const existing = groups.get(dir) || [];
      existing.push(session);
      groups.set(dir, existing);
    }

    return groups;
  }, [filteredSessions, groupByDirectory]);

  // Handle session selection
  const handleSelectSession = useCallback(
    (sessionId: string) => {
      setInternalSelectedId(sessionId);
      onSelectSession(sessionId);
    },
    [onSelectSession]
  );

  // Handle tree node click
  const handleNodeClick = useCallback(
    (nodeId: string, action: 'fork' | 'select') => {
      if (action === 'fork' && activeSessionId) {
        const node = sessionHistory.treeNodes.find((n) => n.id === nodeId);
        setForkConfirmation({
          sessionId: activeSessionId,
          eventId: nodeId,
          eventSummary: node?.summary || 'this event',
        });
      }
    },
    [activeSessionId, sessionHistory.treeNodes]
  );

  // Confirm fork
  const handleConfirmFork = useCallback(() => {
    if (forkConfirmation) {
      onForkFromEvent(forkConfirmation.sessionId, forkConfirmation.eventId);
      setForkConfirmation(null);
      onClose();
    }
  }, [forkConfirmation, onForkFromEvent, onClose]);

  // Cancel fork
  const handleCancelFork = useCallback(() => {
    setForkConfirmation(null);
  }, []);

  // Handle keyboard
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (forkConfirmation) {
          handleCancelFork();
        } else {
          onClose();
        }
      }
    },
    [forkConfirmation, handleCancelFork, onClose]
  );

  if (!isOpen) return null;

  return (
    <div
      className="session-browser-overlay"
      onClick={onClose}
      onKeyDown={handleKeyDown}
      role="dialog"
      aria-modal="true"
      aria-label="Session Browser"
    >
      <div className="session-browser" onClick={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="session-browser-header">
          <h2>Session Browser</h2>
          <button
            className="close-button"
            onClick={onClose}
            title="Close"
            type="button"
          >
            <CloseIcon />
          </button>
        </div>

        {/* Search */}
        <div className="session-browser-search">
          <SearchIcon />
          <input
            type="text"
            placeholder="Search sessions..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            autoFocus
          />
        </div>

        {/* Content */}
        <div className="session-browser-content">
          {/* Session List */}
          <div className="session-list-container">
            {filteredSessions.length === 0 ? (
              <div className="session-list-empty">
                {sessions.length === 0 ? (
                  <>
                    <span className="empty-icon">◇</span>
                    <span>No past sessions</span>
                    <span className="empty-hint">
                      Sessions will appear here as you create them
                    </span>
                  </>
                ) : (
                  <>
                    <span className="empty-icon">🔍</span>
                    <span>No sessions found</span>
                    <span className="empty-hint">
                      Try a different search term
                    </span>
                  </>
                )}
              </div>
            ) : groupedSessions ? (
              <div className="session-groups">
                {Array.from(groupedSessions.entries()).map(([dir, dirSessions]) => (
                  <div key={dir} className="session-group">
                    <div className="session-group-header">
                      <FolderIcon />
                      <span>{dir}</span>
                    </div>
                    <ul className="session-list" role="listbox">
                      {dirSessions.map((session) => (
                        <SessionItem
                          key={session.id}
                          session={session}
                          isSelected={session.id === activeSessionId}
                          onClick={() => handleSelectSession(session.id)}
                        />
                      ))}
                    </ul>
                  </div>
                ))}
              </div>
            ) : (
              <ul className="session-list" role="listbox">
                {filteredSessions.map((session) => (
                  <SessionItem
                    key={session.id}
                    session={session}
                    isSelected={session.id === activeSessionId}
                    onClick={() => handleSelectSession(session.id)}
                  />
                ))}
              </ul>
            )}
          </div>

          {/* Session History Tree */}
          <div className="session-tree-container">
            {activeSessionId ? (
              sessionHistory.isLoading ? (
                <div className="session-tree-loading">
                  <span className="loading-spinner">◌</span>
                  <span>Loading session history...</span>
                </div>
              ) : sessionHistory.events.length === 0 ? (
                <div className="session-tree-empty">
                  <span>No events in this session</span>
                </div>
              ) : (
                <SessionTree
                  nodes={sessionHistory.treeNodes}
                  headNodeId={sessionHistory.headEventId ?? undefined}
                  onNodeClick={handleNodeClick}
                  variant="expanded"
                  title="Session History"
                  maxHeight="100%"
                />
              )
            ) : (
              <div className="session-tree-placeholder">
                <span className="placeholder-icon">←</span>
                <span>Select a session to view its history</span>
              </div>
            )}
          </div>
        </div>

        {/* Fork Confirmation Dialog */}
        {forkConfirmation && (
          <div className="fork-confirmation-overlay">
            <div className="fork-confirmation">
              <h3>Create New Session</h3>
              <p>
                This will create a new session branching from{' '}
                <strong>{forkConfirmation.eventSummary}</strong>.
              </p>
              <p className="fork-note">
                The original session will be preserved. Your new session will
                start with all context up to this point.
              </p>
              <div className="fork-confirmation-actions">
                <button
                  className="cancel-button"
                  onClick={handleCancelFork}
                  type="button"
                >
                  Cancel
                </button>
                <button
                  className="confirm-button"
                  onClick={handleConfirmFork}
                  type="button"
                >
                  Create Session
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
