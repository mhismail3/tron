/**
 * @fileoverview Hook for managing sessions data
 */

import { useEffect, useCallback } from 'react';
import { useDashboard } from '../store/context.js';
import { getContainer } from '../di/index.js';
import * as actions from '../store/actions.js';
import type { ListSessionsOptions } from '../types/session.js';

/**
 * Hook for loading and managing sessions
 */
export function useSessions(options: ListSessionsOptions = {}) {
  const { state, dispatch } = useDashboard();

  const loadSessions = useCallback(async () => {
    dispatch(actions.loadSessionsStart());

    try {
      const container = getContainer();
      const sessions = await container.sessions.listWithStats(options);
      const total = await container.sessions.count(options);
      dispatch(actions.loadSessionsSuccess(sessions, total));
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to load sessions';
      dispatch(actions.loadSessionsError(message));
    }
  }, [dispatch, options.workspaceId, options.ended, options.limit, options.offset]);

  useEffect(() => {
    loadSessions();
  }, [loadSessions]);

  return {
    sessions: state.sessions,
    loading: state.sessionsLoading,
    error: state.sessionsError,
    total: state.totalSessions,
    refresh: loadSessions,
  };
}
