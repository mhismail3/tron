/**
 * @fileoverview Tests for dashboard reducer
 */

import { describe, it, expect } from 'vitest';
import { reducer, initialState } from '../reducer.js';
import type { DashboardState, DashboardAction } from '../types.js';
import type { SessionId, EventId } from '@tron/agent';
import type { DashboardSessionSummary, DashboardStats } from '../../types/index.js';

describe('Dashboard Reducer', () => {
  describe('session list actions', () => {
    it('handles LOAD_SESSIONS_START', () => {
      const state = reducer(initialState, { type: 'LOAD_SESSIONS_START' });
      expect(state.sessionsLoading).toBe(true);
      expect(state.sessionsError).toBeNull();
    });

    it('handles LOAD_SESSIONS_SUCCESS', () => {
      const sessions: DashboardSessionSummary[] = [
        createMockSession('sess_1'),
        createMockSession('sess_2'),
      ];

      const loadingState: DashboardState = {
        ...initialState,
        sessionsLoading: true,
      };

      const state = reducer(loadingState, {
        type: 'LOAD_SESSIONS_SUCCESS',
        payload: { sessions, total: 2 },
      });

      expect(state.sessionsLoading).toBe(false);
      expect(state.sessions).toHaveLength(2);
      expect(state.totalSessions).toBe(2);
    });

    it('handles LOAD_SESSIONS_ERROR', () => {
      const loadingState: DashboardState = {
        ...initialState,
        sessionsLoading: true,
      };

      const state = reducer(loadingState, {
        type: 'LOAD_SESSIONS_ERROR',
        payload: 'Failed to load sessions',
      });

      expect(state.sessionsLoading).toBe(false);
      expect(state.sessionsError).toBe('Failed to load sessions');
    });
  });

  describe('session selection actions', () => {
    it('handles SELECT_SESSION', () => {
      const sessionId = 'sess_test' as SessionId;
      const state = reducer(initialState, {
        type: 'SELECT_SESSION',
        payload: sessionId,
      });

      expect(state.selectedSessionId).toBe(sessionId);
      expect(state.events).toEqual([]);
      expect(state.expandedEventIds.size).toBe(0);
    });

    it('clears events when selecting null', () => {
      const stateWithEvents: DashboardState = {
        ...initialState,
        selectedSessionId: 'sess_old' as SessionId,
        events: [{ id: 'evt_1', type: 'session.start' } as any],
      };

      const state = reducer(stateWithEvents, {
        type: 'SELECT_SESSION',
        payload: null,
      });

      expect(state.selectedSessionId).toBeNull();
      expect(state.events).toEqual([]);
    });

    it('handles LOAD_SESSION_SUCCESS', () => {
      const session = createMockSession('sess_test');
      const state = reducer(initialState, {
        type: 'LOAD_SESSION_SUCCESS',
        payload: session,
      });

      expect(state.selectedSession).toBe(session);
      expect(state.selectedSessionLoading).toBe(false);
    });
  });

  describe('event actions', () => {
    it('handles LOAD_EVENTS_START', () => {
      const state = reducer(initialState, { type: 'LOAD_EVENTS_START' });
      expect(state.eventsLoading).toBe(true);
      expect(state.eventsError).toBeNull();
    });

    it('handles LOAD_EVENTS_SUCCESS', () => {
      const events = [
        { id: 'evt_1' as EventId, type: 'session.start' },
        { id: 'evt_2' as EventId, type: 'message.user' },
      ] as any[];

      const state = reducer(initialState, {
        type: 'LOAD_EVENTS_SUCCESS',
        payload: { events, total: 10, hasMore: true },
      });

      expect(state.eventsLoading).toBe(false);
      expect(state.events).toHaveLength(2);
      expect(state.totalEvents).toBe(10);
      expect(state.hasMoreEvents).toBe(true);
    });

    it('handles APPEND_EVENTS', () => {
      const existingState: DashboardState = {
        ...initialState,
        events: [{ id: 'evt_1' as EventId, type: 'session.start' }] as any[],
      };

      const newEvents = [{ id: 'evt_2' as EventId, type: 'message.user' }] as any[];

      const state = reducer(existingState, {
        type: 'APPEND_EVENTS',
        payload: { events: newEvents, hasMore: false },
      });

      expect(state.events).toHaveLength(2);
      expect(state.hasMoreEvents).toBe(false);
    });
  });

  describe('event filter actions', () => {
    it('handles SET_EVENT_FILTER', () => {
      const state = reducer(initialState, {
        type: 'SET_EVENT_FILTER',
        payload: { errorsOnly: true, search: 'test' },
      });

      expect(state.eventFilter.errorsOnly).toBe(true);
      expect(state.eventFilter.search).toBe('test');
    });

    it('handles CLEAR_EVENT_FILTER', () => {
      const stateWithFilter: DashboardState = {
        ...initialState,
        eventFilter: {
          types: ['message.user'],
          categories: ['message'],
          search: 'test',
          errorsOnly: true,
        },
      };

      const state = reducer(stateWithFilter, { type: 'CLEAR_EVENT_FILTER' });

      expect(state.eventFilter.types).toEqual([]);
      expect(state.eventFilter.search).toBe('');
      expect(state.eventFilter.errorsOnly).toBe(false);
    });
  });

  describe('event expansion actions', () => {
    it('handles TOGGLE_EVENT_EXPANDED - expands collapsed event', () => {
      const eventId = 'evt_test' as EventId;
      const state = reducer(initialState, {
        type: 'TOGGLE_EVENT_EXPANDED',
        payload: eventId,
      });

      expect(state.expandedEventIds.has(eventId)).toBe(true);
    });

    it('handles TOGGLE_EVENT_EXPANDED - collapses expanded event', () => {
      const eventId = 'evt_test' as EventId;
      const expandedState: DashboardState = {
        ...initialState,
        expandedEventIds: new Set([eventId]),
      };

      const state = reducer(expandedState, {
        type: 'TOGGLE_EVENT_EXPANDED',
        payload: eventId,
      });

      expect(state.expandedEventIds.has(eventId)).toBe(false);
    });

    it('handles EXPAND_ALL_EVENTS', () => {
      const events = [
        { id: 'evt_1' as EventId },
        { id: 'evt_2' as EventId },
        { id: 'evt_3' as EventId },
      ] as any[];

      const stateWithEvents: DashboardState = {
        ...initialState,
        events,
      };

      const state = reducer(stateWithEvents, { type: 'EXPAND_ALL_EVENTS' });

      expect(state.expandedEventIds.size).toBe(3);
      expect(state.expandedEventIds.has('evt_1' as EventId)).toBe(true);
      expect(state.expandedEventIds.has('evt_2' as EventId)).toBe(true);
      expect(state.expandedEventIds.has('evt_3' as EventId)).toBe(true);
    });

    it('handles COLLAPSE_ALL_EVENTS', () => {
      const expandedState: DashboardState = {
        ...initialState,
        expandedEventIds: new Set(['evt_1', 'evt_2', 'evt_3'] as EventId[]),
      };

      const state = reducer(expandedState, { type: 'COLLAPSE_ALL_EVENTS' });

      expect(state.expandedEventIds.size).toBe(0);
    });
  });

  describe('UI actions', () => {
    it('handles TOGGLE_SIDEBAR', () => {
      const state1 = reducer(initialState, { type: 'TOGGLE_SIDEBAR' });
      expect(state1.sidebarCollapsed).toBe(true);

      const state2 = reducer(state1, { type: 'TOGGLE_SIDEBAR' });
      expect(state2.sidebarCollapsed).toBe(false);
    });

    it('handles SET_SIDEBAR_COLLAPSED', () => {
      const state = reducer(initialState, {
        type: 'SET_SIDEBAR_COLLAPSED',
        payload: true,
      });
      expect(state.sidebarCollapsed).toBe(true);
    });
  });

  describe('stats actions', () => {
    it('handles LOAD_STATS_SUCCESS', () => {
      const stats: DashboardStats = {
        totalSessions: 100,
        activeSessions: 5,
        totalEvents: 10000,
        totalTokensUsed: 500000,
        totalCost: 25.5,
      };

      const state = reducer(initialState, {
        type: 'LOAD_STATS_SUCCESS',
        payload: stats,
      });

      expect(state.stats).toBe(stats);
      expect(state.statsLoading).toBe(false);
    });
  });

  describe('reset action', () => {
    it('handles RESET', () => {
      const modifiedState: DashboardState = {
        ...initialState,
        sessions: [createMockSession('sess_1')],
        selectedSessionId: 'sess_1' as SessionId,
        events: [{ id: 'evt_1' } as any],
        sidebarCollapsed: true,
      };

      const state = reducer(modifiedState, { type: 'RESET' });

      expect(state).toEqual(initialState);
    });
  });
});

// Helper to create mock session
function createMockSession(id: string): DashboardSessionSummary {
  return {
    id: id as SessionId,
    workspaceId: 'ws_test' as any,
    title: `Session ${id}`,
    workingDirectory: '/test',
    model: 'claude-sonnet-4-20250514',
    createdAt: new Date().toISOString(),
    lastActivityAt: new Date().toISOString(),
    archivedAt: null,
    isArchived: false,
    eventCount: 0,
    messageCount: 0,
    turnCount: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    lastTurnInputTokens: 0,
    totalCost: 0,
    totalCacheReadTokens: 0,
    totalCacheCreationTokens: 0,
    spawningSessionId: null,
    spawnType: null,
    spawnTask: null,
    tags: [],
  };
}
