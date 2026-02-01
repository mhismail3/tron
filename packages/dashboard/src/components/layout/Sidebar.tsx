/**
 * @fileoverview Sidebar navigation component
 */

import React, { memo } from 'react';
import type { DashboardStats } from '../../types/session.js';
import { formatTokenCount, formatCost } from '../../types/session.js';

export interface SidebarProps {
  stats?: DashboardStats | null;
  children?: React.ReactNode;
}

export const Sidebar = memo(function Sidebar({
  stats,
  children,
}: SidebarProps) {
  return (
    <div className="sidebar">
      {stats && (
        <div className="sidebar-stats">
          <div className="sidebar-stat">
            <span className="stat-value">{stats.totalSessions}</span>
            <span className="stat-label">Sessions</span>
          </div>
          <div className="sidebar-stat">
            <span className="stat-value">{stats.activeSessions}</span>
            <span className="stat-label">Active</span>
          </div>
          <div className="sidebar-stat">
            <span className="stat-value">{formatTokenCount(stats.totalTokensUsed)}</span>
            <span className="stat-label">Tokens</span>
          </div>
          <div className="sidebar-stat">
            <span className="stat-value">{formatCost(stats.totalCost)}</span>
            <span className="stat-label">Cost</span>
          </div>
        </div>
      )}

      <div className="sidebar-content">
        {children}
      </div>
    </div>
  );
});
