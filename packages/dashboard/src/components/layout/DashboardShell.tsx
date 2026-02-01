/**
 * @fileoverview Main dashboard layout container
 */

import React, { memo } from 'react';
import { Sidebar } from './Sidebar.js';

export interface DashboardShellProps {
  children: React.ReactNode;
  sidebar?: React.ReactNode;
  sidebarCollapsed?: boolean;
  onToggleSidebar?: () => void;
}

export const DashboardShell = memo(function DashboardShell({
  children,
  sidebar,
  sidebarCollapsed = false,
  onToggleSidebar,
}: DashboardShellProps) {
  return (
    <div className={`dashboard-shell ${sidebarCollapsed ? 'sidebar-collapsed' : ''}`}>
      <header className="dashboard-header">
        <button
          className="dashboard-menu-btn"
          onClick={onToggleSidebar}
          aria-label={sidebarCollapsed ? 'Open sidebar' : 'Close sidebar'}
        >
          ☰
        </button>
        <h1 className="dashboard-title">Tron Session Viewer</h1>
      </header>

      <div className="dashboard-body">
        {sidebar && (
          <aside className="dashboard-sidebar">
            {sidebar}
          </aside>
        )}
        <main className="dashboard-main">
          {children}
        </main>
      </div>
    </div>
  );
});
