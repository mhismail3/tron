/**
 * @fileoverview Session statistics component
 */

import React, { memo } from 'react';
import type { DashboardSessionSummary } from '../../types/session.js';
import { formatTokenCount, formatCost } from '../../types/session.js';

export interface SessionStatsProps {
  session: DashboardSessionSummary;
}

export const SessionStats = memo(function SessionStats({ session }: SessionStatsProps) {
  const totalTokens = session.totalInputTokens + session.totalOutputTokens;

  return (
    <div className="session-stats">
      <div className="session-stats-grid">
        <div className="session-stat">
          <span className="stat-value">{session.messageCount}</span>
          <span className="stat-label">Messages</span>
        </div>
        <div className="session-stat">
          <span className="stat-value">{session.turnCount}</span>
          <span className="stat-label">Turns</span>
        </div>
        <div className="session-stat">
          <span className="stat-value">{session.eventCount}</span>
          <span className="stat-label">Events</span>
        </div>
        <div className="session-stat">
          <span className="stat-value">{formatTokenCount(totalTokens)}</span>
          <span className="stat-label">Total Tokens</span>
        </div>
      </div>

      <div className="session-stats-breakdown">
        <div className="session-stat-row">
          <span className="stat-key">Input Tokens:</span>
          <span className="stat-val">{formatTokenCount(session.totalInputTokens)}</span>
        </div>
        <div className="session-stat-row">
          <span className="stat-key">Output Tokens:</span>
          <span className="stat-val">{formatTokenCount(session.totalOutputTokens)}</span>
        </div>
        <div className="session-stat-row">
          <span className="stat-key">Context Size:</span>
          <span className="stat-val">{formatTokenCount(session.lastTurnInputTokens)}</span>
        </div>
        {session.totalCacheReadTokens > 0 && (
          <div className="session-stat-row">
            <span className="stat-key">Cache Read:</span>
            <span className="stat-val">{formatTokenCount(session.totalCacheReadTokens)}</span>
          </div>
        )}
        {session.totalCacheCreationTokens > 0 && (
          <div className="session-stat-row">
            <span className="stat-key">Cache Created:</span>
            <span className="stat-val">{formatTokenCount(session.totalCacheCreationTokens)}</span>
          </div>
        )}
        <div className="session-stat-row session-stat-row-total">
          <span className="stat-key">Estimated Cost:</span>
          <span className="stat-val">{formatCost(session.totalCost)}</span>
        </div>
      </div>
    </div>
  );
});
