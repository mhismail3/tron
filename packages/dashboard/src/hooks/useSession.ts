/**
 * @fileoverview Hook for managing single session selection
 */

import { useEffect, useCallback } from 'react';
import { useDashboard } from '../store/context.js';
import { getContainer } from '../di/index.js';
import * as actions from '../store/actions.js';
import type { SessionId } from '@tron/agent';

/**
 * Hook for selecting and loading a single session
 */
export function useSession(sessionId: SessionId | null) {
  const { state, dispatch } = useDashboard();

  const selectSession = useCallback((id: SessionId | null) => {
    dispatch(actions.selectSession(id));
  }, [dispatch]);

  useEffect(() => {
    if (!sessionId) return;

    dispatch(actions.loadSessionStart());

    const container = getContainer();
    container.sessions.getById(sessionId)
      .then((session) => {
        if (session) {
          dispatch(actions.loadSessionSuccess(session));
        }
      })
      .catch(() => {
        dispatch(actions.loadSessionError('Failed to load session'));
      });
  }, [dispatch, sessionId]);

  return {
    selectedId: state.selectedSessionId,
    session: state.selectedSession,
    loading: state.selectedSessionLoading,
    select: selectSession,
    clear: () => selectSession(null),
  };
}
