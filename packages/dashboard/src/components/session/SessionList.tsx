/**
 * @fileoverview Session list component
 */

import React, { memo } from 'react';
import type { SessionId } from '@tron/agent';
import type { DashboardSessionSummary } from '../../types/session.js';
import { SessionCard } from './SessionCard.js';
import { Spinner } from '../ui/Spinner.js';

export interface SessionListProps {
  sessions: DashboardSessionSummary[];
  loading?: boolean;
  error?: string | null;
  selectedId?: SessionId | null;
  onSelect?: (id: SessionId) => void;
}

export const SessionList = memo(function SessionList({
  sessions,
  loading = false,
  error = null,
  selectedId = null,
  onSelect,
}: SessionListProps) {
  if (loading && sessions.length === 0) {
    return (
      <div className="session-list-loading">
        <Spinner size="lg" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="session-list-error">
        <span className="error-icon">!</span>
        <span>{error}</span>
      </div>
    );
  }

  if (sessions.length === 0) {
    return (
      <div className="session-list-empty">
        <span>No sessions found</span>
      </div>
    );
  }

  return (
    <div className="session-list">
      {sessions.map((session) => (
        <SessionCard
          key={session.id}
          session={session}
          selected={session.id === selectedId}
          onClick={onSelect}
        />
      ))}
      {loading && (
        <div className="session-list-loading-more">
          <Spinner size="sm" />
        </div>
      )}
    </div>
  );
});
