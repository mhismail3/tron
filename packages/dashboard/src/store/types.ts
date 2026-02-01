/**
 * @fileoverview State types for the dashboard
 */

import type { SessionId, EventId, TronSessionEvent } from '@tron/agent';
import type { DashboardSessionSummary, DashboardStats, EventFilter } from '../types/index.js';

/**
 * Dashboard application state
 */
export interface DashboardState {
  // Session list
  sessions: DashboardSessionSummary[];
  sessionsLoading: boolean;
  sessionsError: string | null;
  totalSessions: number;

  // Selected session
  selectedSessionId: SessionId | null;
  selectedSession: DashboardSessionSummary | null;
  selectedSessionLoading: boolean;

  // Events for selected session
  events: TronSessionEvent[];
  eventsLoading: boolean;
  eventsError: string | null;
  totalEvents: number;
  hasMoreEvents: boolean;

  // Event filtering
  eventFilter: EventFilter;

  // UI state
  sidebarCollapsed: boolean;
  expandedEventIds: Set<EventId>;

  // Dashboard stats
  stats: DashboardStats | null;
  statsLoading: boolean;
}

/**
 * Dashboard actions
 */
export type DashboardAction =
  // Session list actions
  | { type: 'LOAD_SESSIONS_START' }
  | { type: 'LOAD_SESSIONS_SUCCESS'; payload: { sessions: DashboardSessionSummary[]; total: number } }
  | { type: 'LOAD_SESSIONS_ERROR'; payload: string }

  // Session selection actions
  | { type: 'SELECT_SESSION'; payload: SessionId | null }
  | { type: 'LOAD_SESSION_START' }
  | { type: 'LOAD_SESSION_SUCCESS'; payload: DashboardSessionSummary }
  | { type: 'LOAD_SESSION_ERROR'; payload: string }

  // Event actions
  | { type: 'LOAD_EVENTS_START' }
  | { type: 'LOAD_EVENTS_SUCCESS'; payload: { events: TronSessionEvent[]; total: number; hasMore: boolean } }
  | { type: 'LOAD_EVENTS_ERROR'; payload: string }
  | { type: 'APPEND_EVENTS'; payload: { events: TronSessionEvent[]; hasMore: boolean } }

  // Event filtering
  | { type: 'SET_EVENT_FILTER'; payload: Partial<EventFilter> }
  | { type: 'CLEAR_EVENT_FILTER' }

  // Event expansion
  | { type: 'TOGGLE_EVENT_EXPANDED'; payload: EventId }
  | { type: 'EXPAND_ALL_EVENTS' }
  | { type: 'COLLAPSE_ALL_EVENTS' }

  // UI actions
  | { type: 'TOGGLE_SIDEBAR' }
  | { type: 'SET_SIDEBAR_COLLAPSED'; payload: boolean }

  // Stats actions
  | { type: 'LOAD_STATS_START' }
  | { type: 'LOAD_STATS_SUCCESS'; payload: DashboardStats }
  | { type: 'LOAD_STATS_ERROR'; payload: string }

  // Reset
  | { type: 'RESET' };
