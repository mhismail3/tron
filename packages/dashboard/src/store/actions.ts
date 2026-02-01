/**
 * @fileoverview Action creators for dashboard state
 */

import type { SessionId, EventId, TronSessionEvent } from '@tron/agent';
import type { DashboardAction } from './types.js';
import type { DashboardSessionSummary, DashboardStats, EventFilter } from '../types/index.js';

// =============================================================================
// Session List Actions
// =============================================================================

export const loadSessionsStart = (): DashboardAction => ({
  type: 'LOAD_SESSIONS_START',
});

export const loadSessionsSuccess = (
  sessions: DashboardSessionSummary[],
  total: number
): DashboardAction => ({
  type: 'LOAD_SESSIONS_SUCCESS',
  payload: { sessions, total },
});

export const loadSessionsError = (error: string): DashboardAction => ({
  type: 'LOAD_SESSIONS_ERROR',
  payload: error,
});

// =============================================================================
// Session Selection Actions
// =============================================================================

export const selectSession = (sessionId: SessionId | null): DashboardAction => ({
  type: 'SELECT_SESSION',
  payload: sessionId,
});

export const loadSessionStart = (): DashboardAction => ({
  type: 'LOAD_SESSION_START',
});

export const loadSessionSuccess = (session: DashboardSessionSummary): DashboardAction => ({
  type: 'LOAD_SESSION_SUCCESS',
  payload: session,
});

export const loadSessionError = (error: string): DashboardAction => ({
  type: 'LOAD_SESSION_ERROR',
  payload: error,
});

// =============================================================================
// Event Actions
// =============================================================================

export const loadEventsStart = (): DashboardAction => ({
  type: 'LOAD_EVENTS_START',
});

export const loadEventsSuccess = (
  events: TronSessionEvent[],
  total: number,
  hasMore: boolean
): DashboardAction => ({
  type: 'LOAD_EVENTS_SUCCESS',
  payload: { events, total, hasMore },
});

export const loadEventsError = (error: string): DashboardAction => ({
  type: 'LOAD_EVENTS_ERROR',
  payload: error,
});

export const appendEvents = (
  events: TronSessionEvent[],
  hasMore: boolean
): DashboardAction => ({
  type: 'APPEND_EVENTS',
  payload: { events, hasMore },
});

// =============================================================================
// Event Filter Actions
// =============================================================================

export const setEventFilter = (filter: Partial<EventFilter>): DashboardAction => ({
  type: 'SET_EVENT_FILTER',
  payload: filter,
});

export const clearEventFilter = (): DashboardAction => ({
  type: 'CLEAR_EVENT_FILTER',
});

// =============================================================================
// Event Expansion Actions
// =============================================================================

export const toggleEventExpanded = (eventId: EventId): DashboardAction => ({
  type: 'TOGGLE_EVENT_EXPANDED',
  payload: eventId,
});

export const expandAllEvents = (): DashboardAction => ({
  type: 'EXPAND_ALL_EVENTS',
});

export const collapseAllEvents = (): DashboardAction => ({
  type: 'COLLAPSE_ALL_EVENTS',
});

// =============================================================================
// UI Actions
// =============================================================================

export const toggleSidebar = (): DashboardAction => ({
  type: 'TOGGLE_SIDEBAR',
});

export const setSidebarCollapsed = (collapsed: boolean): DashboardAction => ({
  type: 'SET_SIDEBAR_COLLAPSED',
  payload: collapsed,
});

// =============================================================================
// Stats Actions
// =============================================================================

export const loadStatsStart = (): DashboardAction => ({
  type: 'LOAD_STATS_START',
});

export const loadStatsSuccess = (stats: DashboardStats): DashboardAction => ({
  type: 'LOAD_STATS_SUCCESS',
  payload: stats,
});

export const loadStatsError = (error: string): DashboardAction => ({
  type: 'LOAD_STATS_ERROR',
  payload: error,
});

// =============================================================================
// Reset
// =============================================================================

export const reset = (): DashboardAction => ({
  type: 'RESET',
});
