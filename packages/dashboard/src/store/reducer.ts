/**
 * @fileoverview Dashboard state reducer
 */

import type { EventId } from '@tron/agent';
import type { DashboardState, DashboardAction } from './types.js';
import { defaultEventFilter } from '../types/display.js';

/**
 * Initial dashboard state
 */
export const initialState: DashboardState = {
  // Session list
  sessions: [],
  sessionsLoading: false,
  sessionsError: null,
  totalSessions: 0,

  // Selected session
  selectedSessionId: null,
  selectedSession: null,
  selectedSessionLoading: false,

  // Events
  events: [],
  eventsLoading: false,
  eventsError: null,
  totalEvents: 0,
  hasMoreEvents: false,

  // Filtering
  eventFilter: { ...defaultEventFilter },

  // UI
  sidebarCollapsed: false,
  expandedEventIds: new Set(),

  // Stats
  stats: null,
  statsLoading: false,
};

/**
 * Dashboard reducer
 */
export function reducer(state: DashboardState, action: DashboardAction): DashboardState {
  switch (action.type) {
    // =========================================================================
    // Session List
    // =========================================================================

    case 'LOAD_SESSIONS_START':
      return {
        ...state,
        sessionsLoading: true,
        sessionsError: null,
      };

    case 'LOAD_SESSIONS_SUCCESS':
      return {
        ...state,
        sessionsLoading: false,
        sessions: action.payload.sessions,
        totalSessions: action.payload.total,
      };

    case 'LOAD_SESSIONS_ERROR':
      return {
        ...state,
        sessionsLoading: false,
        sessionsError: action.payload,
      };

    // =========================================================================
    // Session Selection
    // =========================================================================

    case 'SELECT_SESSION':
      return {
        ...state,
        selectedSessionId: action.payload,
        selectedSession: null,
        events: [],
        eventsError: null,
        expandedEventIds: new Set(),
      };

    case 'LOAD_SESSION_START':
      return {
        ...state,
        selectedSessionLoading: true,
      };

    case 'LOAD_SESSION_SUCCESS':
      return {
        ...state,
        selectedSessionLoading: false,
        selectedSession: action.payload,
      };

    case 'LOAD_SESSION_ERROR':
      return {
        ...state,
        selectedSessionLoading: false,
      };

    // =========================================================================
    // Events
    // =========================================================================

    case 'LOAD_EVENTS_START':
      return {
        ...state,
        eventsLoading: true,
        eventsError: null,
      };

    case 'LOAD_EVENTS_SUCCESS':
      return {
        ...state,
        eventsLoading: false,
        events: action.payload.events,
        totalEvents: action.payload.total,
        hasMoreEvents: action.payload.hasMore,
      };

    case 'LOAD_EVENTS_ERROR':
      return {
        ...state,
        eventsLoading: false,
        eventsError: action.payload,
      };

    case 'APPEND_EVENTS':
      return {
        ...state,
        events: [...state.events, ...action.payload.events],
        hasMoreEvents: action.payload.hasMore,
      };

    // =========================================================================
    // Event Filtering
    // =========================================================================

    case 'SET_EVENT_FILTER':
      return {
        ...state,
        eventFilter: {
          ...state.eventFilter,
          ...action.payload,
        },
      };

    case 'CLEAR_EVENT_FILTER':
      return {
        ...state,
        eventFilter: { ...defaultEventFilter },
      };

    // =========================================================================
    // Event Expansion
    // =========================================================================

    case 'TOGGLE_EVENT_EXPANDED': {
      const eventId = action.payload;
      const newExpanded = new Set(state.expandedEventIds);
      if (newExpanded.has(eventId)) {
        newExpanded.delete(eventId);
      } else {
        newExpanded.add(eventId);
      }
      return {
        ...state,
        expandedEventIds: newExpanded,
      };
    }

    case 'EXPAND_ALL_EVENTS':
      return {
        ...state,
        expandedEventIds: new Set(state.events.map((e) => e.id as EventId)),
      };

    case 'COLLAPSE_ALL_EVENTS':
      return {
        ...state,
        expandedEventIds: new Set(),
      };

    // =========================================================================
    // UI
    // =========================================================================

    case 'TOGGLE_SIDEBAR':
      return {
        ...state,
        sidebarCollapsed: !state.sidebarCollapsed,
      };

    case 'SET_SIDEBAR_COLLAPSED':
      return {
        ...state,
        sidebarCollapsed: action.payload,
      };

    // =========================================================================
    // Stats
    // =========================================================================

    case 'LOAD_STATS_START':
      return {
        ...state,
        statsLoading: true,
      };

    case 'LOAD_STATS_SUCCESS':
      return {
        ...state,
        statsLoading: false,
        stats: action.payload,
      };

    case 'LOAD_STATS_ERROR':
      return {
        ...state,
        statsLoading: false,
      };

    // =========================================================================
    // Reset
    // =========================================================================

    case 'RESET':
      return { ...initialState };

    default:
      return state;
  }
}
