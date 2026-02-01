/**
 * @fileoverview Session card component for session list
 */

import React, { memo } from 'react';
import type { SessionId } from '@tron/agent';
import type { DashboardSessionSummary } from '../../types/session.js';
import { formatRelativeTime, formatTokenCount, formatCost, truncateText } from '../../types/session.js';
import { Badge } from '../ui/Badge.js';

export interface SessionCardProps {
  session: DashboardSessionSummary;
  selected?: boolean;
  onClick?: (id: SessionId) => void;
}

export const SessionCard = memo(function SessionCard({
  session,
  selected = false,
  onClick,
}: SessionCardProps) {
  const handleClick = () => {
    onClick?.(session.id);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleClick();
    }
  };

  return (
    <div
      className={`session-card ${selected ? 'session-card-selected' : ''}`}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      role="button"
      tabIndex={0}
      aria-selected={selected}
    >
      <div className="session-card-header">
        <span className="session-card-title">
          {session.title || truncateText(session.workingDirectory, 40)}
        </span>
        <span className="session-card-time">
          {formatRelativeTime(session.lastActivityAt)}
        </span>
      </div>

      <div className="session-card-meta">
        <span className="session-card-dir" title={session.workingDirectory}>
          {truncateText(session.workingDirectory, 50)}
        </span>
      </div>

      <div className="session-card-stats">
        <Badge variant={session.isEnded ? 'default' : 'success'} size="sm">
          {session.isEnded ? 'Ended' : 'Active'}
        </Badge>
        <span className="session-card-stat">
          {session.messageCount} msgs
        </span>
        <span className="session-card-stat">
          {formatTokenCount(session.totalInputTokens + session.totalOutputTokens)} tokens
        </span>
        {session.totalCost > 0 && (
          <span className="session-card-stat">
            {formatCost(session.totalCost)}
          </span>
        )}
      </div>

      {session.lastUserPrompt && (
        <div className="session-card-preview">
          <span className="session-card-preview-label">Last:</span>
          <span className="session-card-preview-text">
            {truncateText(session.lastUserPrompt, 80)}
          </span>
        </div>
      )}

      {session.spawnType && (
        <div className="session-card-subagent">
          <Badge variant="info" size="sm">
            {session.spawnType}
          </Badge>
          {session.spawnTask && (
            <span className="session-card-task">
              {truncateText(session.spawnTask, 60)}
            </span>
          )}
        </div>
      )}
    </div>
  );
});
