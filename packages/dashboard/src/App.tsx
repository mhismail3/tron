/**
 * @fileoverview Main dashboard application component
 */

import React, { useEffect, useCallback } from 'react';
import { DashboardProvider, useDashboard } from './store/context.js';
import { initializeContainer } from './di/index.js';
import { DashboardShell } from './components/layout/DashboardShell.js';
import { Sidebar } from './components/layout/Sidebar.js';
import { SessionList } from './components/session/SessionList.js';
import { SessionDetail } from './components/session/SessionDetail.js';
import { EventTimeline } from './components/event/EventTimeline.js';
import { Spinner } from './components/ui/Spinner.js';
import * as actions from './store/actions.js';
import type { SessionId, EventId, TronSessionEvent } from '@tron/agent';
import type {
  DashboardSessionSummary,
  DashboardStats,
  TokenUsageSummary,
  PaginationOptions,
  PaginatedResult,
  ListSessionsOptions,
} from './types/session.js';
import type { TimelineEntry } from './types/display.js';
import type { IDashboardSessionRepository, IDashboardEventRepository } from './data/repositories/types.js';

// =============================================================================
// API Client Repository Implementations
// =============================================================================

class ApiSessionRepository implements IDashboardSessionRepository {
  async listWithStats(options: ListSessionsOptions = {}): Promise<DashboardSessionSummary[]> {
    const params = new URLSearchParams();
    if (options.limit) params.set('limit', String(options.limit));
    if (options.offset) params.set('offset', String(options.offset));
    if (options.ended !== undefined) params.set('ended', String(options.ended));

    const response = await fetch(`/api/sessions?${params}`);
    const data = await response.json();
    return data.sessions;
  }

  async getById(sessionId: SessionId): Promise<DashboardSessionSummary | null> {
    const response = await fetch(`/api/sessions/${sessionId}`);
    if (!response.ok) return null;
    const data = await response.json();
    return data.session;
  }

  async getSessionTimeline(sessionId: SessionId, options?: PaginationOptions): Promise<TimelineEntry[]> {
    // Not implemented for API client
    return [];
  }

  async getTokenUsageBySession(sessionId: SessionId): Promise<TokenUsageSummary> {
    const session = await this.getById(sessionId);
    if (!session) {
      return {
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        estimatedCost: 0,
      };
    }
    return {
      inputTokens: session.totalInputTokens,
      outputTokens: session.totalOutputTokens,
      totalTokens: session.totalInputTokens + session.totalOutputTokens,
      cacheReadTokens: session.totalCacheReadTokens,
      cacheCreationTokens: session.totalCacheCreationTokens,
      estimatedCost: session.totalCost,
    };
  }

  async getStats(): Promise<DashboardStats> {
    const response = await fetch('/api/stats');
    return response.json();
  }

  async count(options?: Pick<ListSessionsOptions, 'workspaceId' | 'ended'>): Promise<number> {
    const params = new URLSearchParams();
    if (options?.ended !== undefined) params.set('ended', String(options.ended));

    const response = await fetch(`/api/sessions?${params}&limit=0`);
    const data = await response.json();
    return data.total;
  }
}

class ApiEventRepository implements IDashboardEventRepository {
  async getEventsBySession(
    sessionId: SessionId,
    options?: PaginationOptions
  ): Promise<PaginatedResult<TronSessionEvent>> {
    const params = new URLSearchParams();
    if (options?.limit) params.set('limit', String(options.limit));
    if (options?.offset) params.set('offset', String(options.offset));

    const response = await fetch(`/api/sessions/${sessionId}/events?${params}`);
    const data = await response.json();
    return {
      items: data.events,
      total: data.total,
      limit: options?.limit ?? 500,
      offset: options?.offset ?? 0,
      hasMore: data.hasMore,
    };
  }

  async getEventsByType(
    sessionId: SessionId,
    types: string[],
    options?: PaginationOptions
  ): Promise<PaginatedResult<TronSessionEvent>> {
    const params = new URLSearchParams();
    params.set('types', types.join(','));
    if (options?.limit) params.set('limit', String(options.limit));
    if (options?.offset) params.set('offset', String(options.offset));

    const response = await fetch(`/api/sessions/${sessionId}/events?${params}`);
    const data = await response.json();
    return {
      items: data.events,
      total: data.total,
      limit: options?.limit ?? 500,
      offset: options?.offset ?? 0,
      hasMore: data.hasMore,
    };
  }

  async getById(eventId: EventId): Promise<TronSessionEvent | null> {
    // Not implemented for API client
    return null;
  }

  async search(
    sessionId: SessionId,
    query: string,
    options?: PaginationOptions
  ): Promise<PaginatedResult<TronSessionEvent>> {
    // Not implemented for API client
    return { items: [], total: 0, limit: 100, offset: 0, hasMore: false };
  }

  async countBySession(sessionId: SessionId): Promise<number> {
    const result = await this.getEventsBySession(sessionId, { limit: 0, offset: 0 });
    return result.total;
  }
}

// Initialize the container with API repositories
initializeContainer({
  sessions: new ApiSessionRepository(),
  events: new ApiEventRepository(),
});

// =============================================================================
// Dashboard Content Component
// =============================================================================

function DashboardContent() {
  const { state, dispatch } = useDashboard();

  // Load sessions on mount
  useEffect(() => {
    loadSessions();
    loadStats();
  }, []);

  // Load events when session is selected
  useEffect(() => {
    if (state.selectedSessionId) {
      loadEvents(state.selectedSessionId);
    }
  }, [state.selectedSessionId]);

  const loadSessions = useCallback(async () => {
    dispatch(actions.loadSessionsStart());
    try {
      const sessionRepo = new ApiSessionRepository();
      const sessions = await sessionRepo.listWithStats({ limit: 100 });
      const total = await sessionRepo.count();
      dispatch(actions.loadSessionsSuccess(sessions, total));
    } catch (error) {
      dispatch(actions.loadSessionsError(
        error instanceof Error ? error.message : 'Failed to load sessions'
      ));
    }
  }, [dispatch]);

  const loadStats = useCallback(async () => {
    dispatch(actions.loadStatsStart());
    try {
      const sessionRepo = new ApiSessionRepository();
      const stats = await sessionRepo.getStats();
      dispatch(actions.loadStatsSuccess(stats));
    } catch {
      // Ignore stats errors
    }
  }, [dispatch]);

  const loadEvents = useCallback(async (sessionId: SessionId) => {
    dispatch(actions.loadEventsStart());
    try {
      const eventRepo = new ApiEventRepository();
      const result = await eventRepo.getEventsBySession(sessionId, { limit: 500, offset: 0 });
      dispatch(actions.loadEventsSuccess(result.items, result.total, result.hasMore));
    } catch (error) {
      dispatch(actions.loadEventsError(
        error instanceof Error ? error.message : 'Failed to load events'
      ));
    }
  }, [dispatch]);

  const loadMoreEvents = useCallback(async () => {
    if (!state.selectedSessionId || !state.hasMoreEvents || state.eventsLoading) return;

    try {
      const eventRepo = new ApiEventRepository();
      const result = await eventRepo.getEventsBySession(state.selectedSessionId, {
        limit: 500,
        offset: state.events.length,
      });
      dispatch(actions.appendEvents(result.items, result.hasMore));
    } catch (error) {
      dispatch(actions.loadEventsError(
        error instanceof Error ? error.message : 'Failed to load more events'
      ));
    }
  }, [dispatch, state.selectedSessionId, state.events.length, state.hasMoreEvents, state.eventsLoading]);

  const selectSession = useCallback(async (id: SessionId) => {
    dispatch(actions.selectSession(id));

    // Load session details
    dispatch(actions.loadSessionStart());
    try {
      const sessionRepo = new ApiSessionRepository();
      const session = await sessionRepo.getById(id);
      if (session) {
        dispatch(actions.loadSessionSuccess(session));
      }
    } catch {
      dispatch(actions.loadSessionError('Failed to load session'));
    }
  }, [dispatch]);

  const clearSession = useCallback(() => {
    dispatch(actions.selectSession(null));
  }, [dispatch]);

  const toggleSidebar = useCallback(() => {
    dispatch(actions.toggleSidebar());
  }, [dispatch]);

  const toggleEventExpanded = useCallback((id: EventId) => {
    dispatch(actions.toggleEventExpanded(id));
  }, [dispatch]);

  const expandAllEvents = useCallback(() => {
    dispatch(actions.expandAllEvents());
  }, [dispatch]);

  const collapseAllEvents = useCallback(() => {
    dispatch(actions.collapseAllEvents());
  }, [dispatch]);

  const sidebar = (
    <Sidebar stats={state.stats}>
      <SessionList
        sessions={state.sessions}
        loading={state.sessionsLoading}
        error={state.sessionsError}
        selectedId={state.selectedSessionId}
        onSelect={selectSession}
      />
    </Sidebar>
  );

  return (
    <DashboardShell
      sidebar={sidebar}
      sidebarCollapsed={state.sidebarCollapsed}
      onToggleSidebar={toggleSidebar}
    >
      {state.selectedSession ? (
        <div className="dashboard-content">
          <SessionDetail session={state.selectedSession} onClose={clearSession} />
          <EventTimeline
            events={state.events}
            loading={state.eventsLoading}
            error={state.eventsError}
            expandedIds={state.expandedEventIds}
            onToggleExpanded={toggleEventExpanded}
            onExpandAll={expandAllEvents}
            onCollapseAll={collapseAllEvents}
            onLoadMore={loadMoreEvents}
            hasMore={state.hasMoreEvents}
          />
        </div>
      ) : (
        <div className="dashboard-welcome">
          <h2>Select a session</h2>
          <p>Choose a session from the sidebar to view its events and details.</p>
        </div>
      )}
    </DashboardShell>
  );
}

// =============================================================================
// App Component
// =============================================================================

export function App() {
  return (
    <DashboardProvider>
      <DashboardContent />
    </DashboardProvider>
  );
}
