/**
 * @fileoverview Session detail view component
 */

import React, { memo } from 'react';
import type { DashboardSessionSummary } from '../../types/session.js';
import { formatRelativeTime, formatTokenCount, formatCost } from '../../types/session.js';
import { Badge } from '../ui/Badge.js';
import { SessionStats } from './SessionStats.js';

export interface SessionDetailProps {
  session: DashboardSessionSummary;
  onClose?: () => void;
}

export const SessionDetail = memo(function SessionDetail({
  session,
  onClose,
}: SessionDetailProps) {
  return (
    <div className="session-detail">
      <div className="session-detail-header">
        <div className="session-detail-title-row">
          <h2 className="session-detail-title">
            {session.title || 'Untitled Session'}
          </h2>
          <Badge variant={session.isEnded ? 'default' : 'success'}>
            {session.isEnded ? 'Ended' : 'Active'}
          </Badge>
        </div>
        {onClose && (
          <button className="session-detail-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        )}
      </div>

      <div className="session-detail-meta">
        <div className="session-detail-meta-item">
          <span className="meta-label">Directory:</span>
          <span className="meta-value" title={session.workingDirectory}>
            {session.workingDirectory}
          </span>
        </div>
        <div className="session-detail-meta-item">
          <span className="meta-label">Model:</span>
          <span className="meta-value">{session.model}</span>
        </div>
        <div className="session-detail-meta-item">
          <span className="meta-label">Created:</span>
          <span className="meta-value">
            {new Date(session.createdAt).toLocaleString()}
          </span>
        </div>
        <div className="session-detail-meta-item">
          <span className="meta-label">Last Activity:</span>
          <span className="meta-value">
            {formatRelativeTime(session.lastActivityAt)}
          </span>
        </div>
        {session.endedAt && (
          <div className="session-detail-meta-item">
            <span className="meta-label">Ended:</span>
            <span className="meta-value">
              {new Date(session.endedAt).toLocaleString()}
            </span>
          </div>
        )}
      </div>

      <SessionStats session={session} />

      {session.tags.length > 0 && (
        <div className="session-detail-tags">
          {session.tags.map((tag) => (
            <Badge key={tag} variant="default" size="sm">
              {tag}
            </Badge>
          ))}
        </div>
      )}

      {session.spawnType && (
        <div className="session-detail-subagent">
          <Badge variant="info">Subagent: {session.spawnType}</Badge>
          {session.spawnTask && (
            <p className="session-detail-task">{session.spawnTask}</p>
          )}
        </div>
      )}
    </div>
  );
});
