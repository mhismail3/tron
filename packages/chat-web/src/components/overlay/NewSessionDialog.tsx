/**
 * @fileoverview New Session Dialog
 *
 * Modal for creating new sessions with two modes:
 * 1. Start Fresh - Select a workspace directory for a new session
 * 2. Fork from History - Pick a point in session tree to branch from
 */

import { useState, useCallback, useMemo } from 'react';
import { SessionTree, type TreeNode } from '../tree/index.js';
import type { CachedSession, CachedEvent } from '../../store/event-db.js';
import './NewSessionDialog.css';

// =============================================================================
// Types
// =============================================================================

export interface NewSessionDialogProps {
  /** Whether the dialog is open */
  isOpen: boolean;
  /** Close the dialog */
  onClose: () => void;
  /** Called when user wants to start a fresh session */
  onStartFresh: () => void;
  /** Called when user wants to fork from a specific event */
  onForkFrom: (sessionId: string, eventId: string) => void;
  /** Available sessions to fork from */
  sessions: CachedSession[];
  /** Events for the selected session (for tree visualization) */
  sessionEvents: CachedEvent[];
  /** Callback to load events for a session */
  onLoadSessionEvents: (sessionId: string) => Promise<void>;
  /** Whether loading events */
  isLoading?: boolean;
}

type DialogMode = 'choice' | 'fork';

// =============================================================================
// Icons
// =============================================================================

function CloseIcon() {
  return (
    <svg width="20" height="20" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
    </svg>
  );
}

function FreshIcon() {
  return (
    <svg width="24" height="24" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M12 4v16m8-8H4" />
    </svg>
  );
}

function ForkIcon() {
  return (
    <svg width="24" height="24" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M7 7v10M17 7v3c0 2-3 4-5 4s-5-2-5-4" />
      <circle cx="7" cy="7" r="2" strokeWidth={1.5} />
      <circle cx="17" cy="7" r="2" strokeWidth={1.5} />
      <circle cx="7" cy="17" r="2" strokeWidth={1.5} />
    </svg>
  );
}

// =============================================================================
// Session List Item
// =============================================================================

interface SessionItemProps {
  session: CachedSession;
  isSelected: boolean;
  onSelect: () => void;
}

function SessionListItem({ session, isSelected, onSelect }: SessionItemProps) {
  const projectName = session.workingDirectory.split('/').pop() || 'Unknown';
  const formattedDate = new Date(session.lastActivityAt).toLocaleDateString();

  return (
    <button
      className={`session-list-item ${isSelected ? 'selected' : ''}`}
      onClick={onSelect}
      type="button"
    >
      <div className="session-list-item-header">
        <span className="session-list-item-name">{session.title || projectName}</span>
        <span className="session-list-item-date">{formattedDate}</span>
      </div>
      <div className="session-list-item-meta">
        <span className="session-list-item-model">{session.model}</span>
        <span className="session-list-item-separator">•</span>
        <span className="session-list-item-count">{session.messageCount} messages</span>
      </div>
      <div className="session-list-item-path">{session.workingDirectory}</div>
    </button>
  );
}

// =============================================================================
// Main Component
// =============================================================================

export function NewSessionDialog({
  isOpen,
  onClose,
  onStartFresh,
  onForkFrom,
  sessions,
  sessionEvents,
  onLoadSessionEvents,
  isLoading = false,
}: NewSessionDialogProps) {
  const [mode, setMode] = useState<DialogMode>('choice');
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null);
  const [selectedEventId, setSelectedEventId] = useState<string | null>(null);

  // Reset state when dialog closes
  const handleClose = useCallback(() => {
    setMode('choice');
    setSelectedSessionId(null);
    setSelectedEventId(null);
    onClose();
  }, [onClose]);

  // Handle "Start Fresh" selection
  const handleStartFresh = useCallback(() => {
    handleClose();
    onStartFresh();
  }, [handleClose, onStartFresh]);

  // Handle "Fork from History" selection
  const handleEnterForkMode = useCallback(() => {
    setMode('fork');
    // Select first session by default if available
    if (sessions.length > 0 && !selectedSessionId) {
      const firstSession = sessions[0]!;
      setSelectedSessionId(firstSession.id);
      onLoadSessionEvents(firstSession.id);
    }
  }, [sessions, selectedSessionId, onLoadSessionEvents]);

  // Handle session selection in fork mode
  const handleSessionSelect = useCallback(
    async (sessionId: string) => {
      setSelectedSessionId(sessionId);
      setSelectedEventId(null);
      await onLoadSessionEvents(sessionId);
    },
    [onLoadSessionEvents]
  );

  // Handle node click in tree
  const handleNodeClick = useCallback(
    (nodeId: string, action: 'fork' | 'select') => {
      setSelectedEventId(nodeId);
    },
    []
  );

  // Handle fork confirmation
  const handleForkConfirm = useCallback(() => {
    if (selectedSessionId && selectedEventId) {
      handleClose();
      onForkFrom(selectedSessionId, selectedEventId);
    }
  }, [selectedSessionId, selectedEventId, handleClose, onForkFrom]);

  // Go back to choice mode
  const handleBack = useCallback(() => {
    setMode('choice');
  }, []);

  // Convert events to tree nodes
  const treeNodes: TreeNode[] = useMemo(() => {
    const selectedSession = sessions.find((s) => s.id === selectedSessionId);

    return sessionEvents.map((event) => ({
      id: event.id,
      parentId: event.parentId,
      type: event.type,
      timestamp: event.timestamp,
      summary: getEventSummary(event),
      hasChildren: sessionEvents.some((e) => e.parentId === event.id),
      childCount: sessionEvents.filter((e) => e.parentId === event.id).length,
      depth: 0, // Calculated in tree component
      isBranchPoint: sessionEvents.filter((e) => e.parentId === event.id).length > 1,
      isHead: event.id === selectedSession?.headEventId,
    }));
  }, [sessionEvents, sessions, selectedSessionId]);

  // Get head node ID for the selected session
  const headNodeId = useMemo(() => {
    const selectedSession = sessions.find((s) => s.id === selectedSessionId);
    return selectedSession?.headEventId || undefined;
  }, [sessions, selectedSessionId]);

  // Handle keyboard
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (mode === 'fork') {
          handleBack();
        } else {
          handleClose();
        }
      }
    },
    [mode, handleBack, handleClose]
  );

  if (!isOpen) return null;

  return (
    <div
      className="new-session-overlay"
      onClick={handleClose}
      onKeyDown={handleKeyDown}
      tabIndex={-1}
      role="dialog"
      aria-modal="true"
      aria-label="New session"
    >
      <div className="new-session-dialog" onClick={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="new-session-header">
          {mode === 'fork' && (
            <button className="new-session-back" onClick={handleBack} type="button">
              <BackIcon />
            </button>
          )}
          <span className="new-session-title">
            {mode === 'choice' ? 'New Session' : 'Fork from History'}
          </span>
          <button className="new-session-close" onClick={handleClose} type="button">
            <CloseIcon />
          </button>
        </div>

        {/* Content based on mode */}
        {mode === 'choice' ? (
          <div className="new-session-choices">
            {/* Start Fresh Option */}
            <button className="new-session-choice" onClick={handleStartFresh} type="button">
              <div className="choice-icon">
                <FreshIcon />
              </div>
              <div className="choice-text">
                <span className="choice-title">Start Fresh</span>
                <span className="choice-description">
                  Create a new session with a clean slate
                </span>
              </div>
            </button>

            {/* Fork from History Option */}
            <button
              className="new-session-choice"
              onClick={handleEnterForkMode}
              disabled={sessions.length === 0}
              type="button"
            >
              <div className="choice-icon">
                <ForkIcon />
              </div>
              <div className="choice-text">
                <span className="choice-title">Fork from History</span>
                <span className="choice-description">
                  {sessions.length === 0
                    ? 'No existing sessions to fork from'
                    : `Branch from any point in ${sessions.length} existing session${sessions.length !== 1 ? 's' : ''}`}
                </span>
              </div>
            </button>
          </div>
        ) : (
          <div className="new-session-fork">
            {/* Session List */}
            <div className="fork-sessions">
              <div className="fork-section-title">Select Session</div>
              <div className="fork-session-list">
                {sessions.map((session) => (
                  <SessionListItem
                    key={session.id}
                    session={session}
                    isSelected={session.id === selectedSessionId}
                    onSelect={() => handleSessionSelect(session.id)}
                  />
                ))}
              </div>
            </div>

            {/* Tree Visualization */}
            <div className="fork-tree">
              <div className="fork-section-title">Select Fork Point</div>
              <SessionTree
                nodes={treeNodes}
                headNodeId={headNodeId}
                selectedNodeId={selectedEventId || undefined}
                onNodeClick={handleNodeClick}
                variant="expanded"
                isLoading={isLoading}
                maxHeight="300px"
              />
            </div>

            {/* Fork Button */}
            <div className="fork-actions">
              <button
                className="fork-confirm-button"
                onClick={handleForkConfirm}
                disabled={!selectedEventId}
                type="button"
              >
                Fork from Selected Point
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// =============================================================================
// Helpers
// =============================================================================

function getEventSummary(event: CachedEvent): string {
  const payload = event.payload;

  switch (event.type) {
    case 'session.start':
      return `Session started: ${payload.title || 'New Session'}`;
    case 'session.end':
      return 'Session ended';
    case 'session.fork':
      return `Forked from ${payload.sourceEventId || 'unknown'}`;
    case 'message.user':
      return truncate(String(payload.content || ''), 60);
    case 'message.assistant':
      return truncate(String(payload.content || ''), 60);
    case 'tool.call':
      return `Tool: ${payload.toolName || 'unknown'}`;
    case 'tool.result':
      return `Result: ${payload.success ? 'success' : 'error'}`;
    case 'config.model_switch':
      return `Model: ${payload.previousModel} → ${payload.newModel}`;
    case 'compact.boundary':
      return 'Context compacted';
    default:
      return event.type;
  }
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 3) + '...';
}
