/**
 * @fileoverview Hook for managing session events
 */

import { useEffect, useCallback } from 'react';
import { useDashboard } from '../store/context.js';
import { getContainer } from '../di/index.js';
import * as actions from '../store/actions.js';
import type { SessionId, EventId } from '@tron/agent';

/**
 * Hook for loading and managing events for a session
 */
export function useEvents(sessionId: SessionId | null, limit = 500) {
  const { state, dispatch } = useDashboard();

  const loadEvents = useCallback(async () => {
    if (!sessionId) return;

    dispatch(actions.loadEventsStart());

    try {
      const container = getContainer();
      const result = await container.events.getEventsBySession(sessionId, {
        limit,
        offset: 0,
      });
      dispatch(actions.loadEventsSuccess(result.items, result.total, result.hasMore));
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to load events';
      dispatch(actions.loadEventsError(message));
    }
  }, [dispatch, sessionId, limit]);

  const loadMore = useCallback(async () => {
    if (!sessionId || !state.hasMoreEvents || state.eventsLoading) return;

    try {
      const container = getContainer();
      const result = await container.events.getEventsBySession(sessionId, {
        limit,
        offset: state.events.length,
      });
      dispatch(actions.appendEvents(result.items, result.hasMore));
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to load more events';
      dispatch(actions.loadEventsError(message));
    }
  }, [dispatch, sessionId, limit, state.events.length, state.hasMoreEvents, state.eventsLoading]);

  useEffect(() => {
    loadEvents();
  }, [loadEvents]);

  return {
    events: state.events,
    loading: state.eventsLoading,
    error: state.eventsError,
    total: state.totalEvents,
    hasMore: state.hasMoreEvents,
    refresh: loadEvents,
    loadMore,
    expandedIds: state.expandedEventIds,
    toggleExpanded: (eventId: EventId) => dispatch(actions.toggleEventExpanded(eventId)),
    expandAll: () => dispatch(actions.expandAllEvents()),
    collapseAll: () => dispatch(actions.collapseAllEvents()),
  };
}
