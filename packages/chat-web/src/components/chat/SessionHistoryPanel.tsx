/**
 * @fileoverview Session History Panel
 *
 * A collapsible panel showing the session's event tree with fork/rewind capabilities.
 * Can be toggled from the StatusBar or via keyboard shortcut.
 */

import { useState, useCallback, useMemo } from 'react';
import { SessionTree, CompactTree, type TreeNode } from '../tree/index.js';
import type { CachedEvent } from '../../store/event-db.js';
import './SessionHistoryPanel.css';

// =============================================================================
// Types
// =============================================================================

export interface SessionHistoryPanelProps {
  /** Whether the panel is open */
  isOpen: boolean;
  /** Close the panel */
  onClose: () => void;
  /** Events for the current session */
  events: CachedEvent[];
  /** Current HEAD event ID */
  headEventId: string | null;
  /** Session ID */
  sessionId: string | null;
  /** Callback when user wants to fork from an event */
  onFork: (eventId: string) => void;
  /** Callback when user wants to rewind to an event */
  onRewind: (eventId: string) => void;
  /** Whether an operation is in progress */
  isLoading?: boolean;
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

function ForkIcon() {
  return (
    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 7v10M17 7v3c0 2-3 4-5 4s-5-2-5-4" />
      <circle cx="7" cy="7" r="2" strokeWidth={2} />
      <circle cx="17" cy="7" r="2" strokeWidth={2} />
      <circle cx="7" cy="17" r="2" strokeWidth={2} />
    </svg>
  );
}

function RewindIcon() {
  return (
    <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0019 16V8a1 1 0 00-1.6-.8l-5.334 4zM4.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0011 16V8a1 1 0 00-1.6-.8l-5.334 4z" />
    </svg>
  );
}

// =============================================================================
// Main Component
// =============================================================================

export function SessionHistoryPanel({
  isOpen,
  onClose,
  events,
  headEventId,
  sessionId,
  onFork,
  onRewind,
  isLoading = false,
}: SessionHistoryPanelProps) {
  const [selectedEventId, setSelectedEventId] = useState<string | null>(null);
  const [actionConfirm, setActionConfirm] = useState<{ type: 'fork' | 'rewind'; eventId: string } | null>(null);

  // Convert events to tree nodes
  const treeNodes: TreeNode[] = useMemo(() => {
    return events.map((event) => ({
      id: event.id,
      parentId: event.parentId,
      type: event.type,
      timestamp: event.timestamp,
      summary: getEventSummary(event),
      hasChildren: events.some((e) => e.parentId === event.id),
      childCount: events.filter((e) => e.parentId === event.id).length,
      depth: 0,
      isBranchPoint: events.filter((e) => e.parentId === event.id).length > 1,
      isHead: event.id === headEventId,
    }));
  }, [events, headEventId]);

  // Handle node click
  const handleNodeClick = useCallback(
    (nodeId: string, action: 'fork' | 'rewind' | 'select') => {
      if (action === 'select') {
        setSelectedEventId(nodeId);
        setActionConfirm(null);
      } else if (action === 'fork' || action === 'rewind') {
        setSelectedEventId(nodeId);
        setActionConfirm({ type: action, eventId: nodeId });
      }
    },
    []
  );

  // Confirm action
  const handleConfirmAction = useCallback(() => {
    if (!actionConfirm) return;

    if (actionConfirm.type === 'fork') {
      onFork(actionConfirm.eventId);
    } else {
      onRewind(actionConfirm.eventId);
    }

    setActionConfirm(null);
    onClose();
  }, [actionConfirm, onFork, onRewind, onClose]);

  // Cancel action
  const handleCancelAction = useCallback(() => {
    setActionConfirm(null);
  }, []);

  // Handle keyboard
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (actionConfirm) {
          handleCancelAction();
        } else {
          onClose();
        }
      }
    },
    [actionConfirm, handleCancelAction, onClose]
  );

  // Find selected event for preview
  const selectedEvent = useMemo(() => {
    return events.find((e) => e.id === selectedEventId);
  }, [events, selectedEventId]);

  if (!isOpen) return null;

  return (
    <div
      className="session-history-panel"
      onKeyDown={handleKeyDown}
      tabIndex={-1}
      role="complementary"
      aria-label="Session history"
    >
      {/* Header */}
      <div className="history-panel-header">
        <span className="history-panel-title">Session History</span>
        <button className="history-panel-close" onClick={onClose} type="button">
          <CloseIcon />
        </button>
      </div>

      {/* Stats */}
      <div className="history-panel-stats">
        <span className="history-stat">
          <span className="stat-value">{events.length}</span>
          <span className="stat-label">events</span>
        </span>
        <span className="history-stat">
          <span className="stat-value">
            {treeNodes.filter((n) => n.isBranchPoint).length}
          </span>
          <span className="stat-label">branches</span>
        </span>
      </div>

      {/* Tree */}
      <div className="history-panel-tree">
        <SessionTree
          nodes={treeNodes}
          headNodeId={headEventId || undefined}
          selectedNodeId={selectedEventId || undefined}
          onNodeClick={handleNodeClick}
          variant="expanded"
          isLoading={isLoading}
          maxHeight="100%"
        />
      </div>

      {/* Selected Event Preview */}
      {selectedEvent && !actionConfirm && (
        <div className="history-panel-preview">
          <div className="preview-header">
            <span className="preview-type">
              {selectedEvent.type.replace('.', ' ')}
            </span>
            <span className="preview-time">
              {new Date(selectedEvent.timestamp).toLocaleTimeString()}
            </span>
          </div>
          <div className="preview-content">{getEventSummary(selectedEvent)}</div>
          {selectedEventId !== headEventId && (
            <div className="preview-actions">
              <button
                className="preview-action fork"
                onClick={() =>
                  handleNodeClick(selectedEventId!, 'fork')
                }
                type="button"
              >
                <ForkIcon />
                Fork
              </button>
              <button
                className="preview-action rewind"
                onClick={() =>
                  handleNodeClick(selectedEventId!, 'rewind')
                }
                type="button"
              >
                <RewindIcon />
                Rewind
              </button>
            </div>
          )}
        </div>
      )}

      {/* Action Confirmation */}
      {actionConfirm && (
        <div className="history-panel-confirm">
          <div className="confirm-message">
            {actionConfirm.type === 'fork' ? (
              <>
                <strong>Fork session?</strong>
                <p>
                  This will create a new branch from this point. Your current
                  work will be preserved on the original branch.
                </p>
              </>
            ) : (
              <>
                <strong>Rewind session?</strong>
                <p>
                  This will move HEAD back to this point. Events after this
                  point will remain in history but won't be visible.
                </p>
              </>
            )}
          </div>
          <div className="confirm-actions">
            <button
              className="confirm-cancel"
              onClick={handleCancelAction}
              type="button"
            >
              Cancel
            </button>
            <button
              className={`confirm-proceed ${actionConfirm.type}`}
              onClick={handleConfirmAction}
              type="button"
            >
              {actionConfirm.type === 'fork' ? 'Fork' : 'Rewind'}
            </button>
          </div>
        </div>
      )}

      {/* Empty State */}
      {events.length === 0 && !isLoading && (
        <div className="history-panel-empty">
          <span className="empty-icon">◇</span>
          <span className="empty-text">No history yet</span>
          <span className="empty-hint">
            Events will appear here as you interact with the session
          </span>
        </div>
      )}
    </div>
  );
}

// =============================================================================
// Compact History Button (for StatusBar)
// =============================================================================

export interface HistoryButtonProps {
  /** Number of events in the session */
  eventCount: number;
  /** Number of branch points */
  branchCount: number;
  /** Click handler */
  onClick: () => void;
}

export function HistoryButton({ eventCount, branchCount, onClick }: HistoryButtonProps) {
  return (
    <button
      className="history-button"
      onClick={onClick}
      title="View session history"
      type="button"
    >
      <span className="history-button-icon">◇</span>
      <span className="history-button-text">
        {eventCount} events
        {branchCount > 0 && ` • ${branchCount} branches`}
      </span>
    </button>
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
      return truncate(String(payload.content || ''), 80);
    case 'message.assistant':
      return truncate(String(payload.content || ''), 80);
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
