/**
 * @fileoverview Session Persistence Hook
 *
 * Manages localStorage persistence for sessions and their state.
 * Ensures sessions survive page reloads and are tracked properly.
 */

import { useCallback, useEffect, useRef } from 'react';
import type { DisplayMessage, SessionSummary } from '../store/types.js';

// =============================================================================
// Types
// =============================================================================

export interface PersistedSessionState {
  sessionId: string;
  messages: DisplayMessage[];
  model: string;
  tokenUsage: { input: number; output: number };
  createdAt: string;
  lastActivity: string;
  workingDirectory: string;
}

export interface PersistedState {
  sessions: SessionSummary[];
  sessionStates: Record<string, PersistedSessionState>;
  activeSessionId: string | null;
  version: number;
}

// =============================================================================
// Constants
// =============================================================================

const STORAGE_KEY = 'tron_web_sessions';
const CURRENT_VERSION = 1;
const DEBOUNCE_MS = 500; // Debounce localStorage writes for performance

// =============================================================================
// Storage Utilities
// =============================================================================

function loadPersistedState(): PersistedState | null {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) return null;

    const parsed = JSON.parse(stored) as PersistedState;

    // Version check for migrations
    if (parsed.version !== CURRENT_VERSION) {
      console.log('[SessionPersistence] Version mismatch, clearing storage');
      localStorage.removeItem(STORAGE_KEY);
      return null;
    }

    return parsed;
  } catch (err) {
    console.error('[SessionPersistence] Failed to load state:', err);
    return null;
  }
}

function savePersistedState(state: PersistedState): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (err) {
    console.error('[SessionPersistence] Failed to save state:', err);
  }
}

function createEmptyPersistedState(): PersistedState {
  return {
    sessions: [],
    sessionStates: {},
    activeSessionId: null,
    version: CURRENT_VERSION,
  };
}

// =============================================================================
// Hook
// =============================================================================

export interface UseSessionPersistenceOptions {
  onSessionsLoaded?: (sessions: SessionSummary[], activeSessionId: string | null) => void;
  onSessionStateLoaded?: (sessionId: string, state: PersistedSessionState) => void;
}

export interface UseSessionPersistenceReturn {
  /** Load all persisted sessions */
  loadSessions: () => { sessions: SessionSummary[]; activeSessionId: string | null };
  /** Load a specific session's state */
  loadSessionState: (sessionId: string) => PersistedSessionState | null;
  /** Save a session to persistence */
  saveSession: (session: SessionSummary) => void;
  /** Save session state (messages, model, etc.) */
  saveSessionState: (sessionId: string, state: Partial<PersistedSessionState>) => void;
  /** Update the active session ID */
  setActiveSession: (sessionId: string | null) => void;
  /** Remove a session from persistence */
  removeSession: (sessionId: string) => void;
  /** Check if a session exists in persistence */
  hasSession: (sessionId: string) => boolean;
  /** Get all session IDs */
  getSessionIds: () => string[];
}

export function useSessionPersistence(
  options: UseSessionPersistenceOptions = {}
): UseSessionPersistenceReturn {
  const stateRef = useRef<PersistedState>(loadPersistedState() || createEmptyPersistedState());
  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Debounced save to reduce localStorage writes
  const debouncedSave = useCallback(() => {
    if (saveTimerRef.current) {
      clearTimeout(saveTimerRef.current);
    }
    saveTimerRef.current = setTimeout(() => {
      savePersistedState(stateRef.current);
      saveTimerRef.current = null;
    }, DEBOUNCE_MS);
  }, []);

  // Immediate save for critical updates (like session deletion)
  const immediateSave = useCallback(() => {
    if (saveTimerRef.current) {
      clearTimeout(saveTimerRef.current);
      saveTimerRef.current = null;
    }
    savePersistedState(stateRef.current);
  }, []);

  // Flush pending saves on unmount
  useEffect(() => {
    return () => {
      if (saveTimerRef.current) {
        clearTimeout(saveTimerRef.current);
        savePersistedState(stateRef.current);
      }
    };
  }, []);

  // Load sessions on mount
  useEffect(() => {
    const state = stateRef.current;
    if (options.onSessionsLoaded && state.sessions.length > 0) {
      options.onSessionsLoaded(state.sessions, state.activeSessionId);
    }
  }, [options.onSessionsLoaded]);

  const loadSessions = useCallback(() => {
    const state = loadPersistedState() || createEmptyPersistedState();
    stateRef.current = state;
    return { sessions: state.sessions, activeSessionId: state.activeSessionId };
  }, []);

  const loadSessionState = useCallback((sessionId: string): PersistedSessionState | null => {
    const state = stateRef.current;
    return state.sessionStates[sessionId] || null;
  }, []);

  const saveSession = useCallback((session: SessionSummary) => {
    const state = stateRef.current;

    // Update or add session
    const existingIndex = state.sessions.findIndex((s) => s.id === session.id);
    if (existingIndex >= 0) {
      state.sessions[existingIndex] = session;
    } else {
      state.sessions.push(session);
    }

    // Use immediate save for new sessions
    immediateSave();
  }, [immediateSave]);

  const saveSessionState = useCallback(
    (sessionId: string, partialState: Partial<PersistedSessionState>) => {
      const state = stateRef.current;

      const existing = state.sessionStates[sessionId];
      const now = new Date().toISOString();

      state.sessionStates[sessionId] = {
        sessionId,
        messages: partialState.messages ?? existing?.messages ?? [],
        model: partialState.model ?? existing?.model ?? 'claude-opus-4-5-20251101',
        tokenUsage: partialState.tokenUsage ?? existing?.tokenUsage ?? { input: 0, output: 0 },
        createdAt: existing?.createdAt ?? now,
        lastActivity: now,
        workingDirectory: partialState.workingDirectory ?? existing?.workingDirectory ?? '/project',
      };

      // Also update the session summary if it exists
      const summaryIndex = state.sessions.findIndex((s) => s.id === sessionId);
      if (summaryIndex >= 0) {
        const summary = state.sessions[summaryIndex]!;
        state.sessions[summaryIndex] = {
          ...summary,
          lastActivity: now,
          messageCount: state.sessionStates[sessionId]!.messages.length,
          model: state.sessionStates[sessionId]!.model,
        };
      }

      // Use debounced save for session state updates (called frequently during streaming)
      debouncedSave();
    },
    [debouncedSave]
  );

  const setActiveSession = useCallback((sessionId: string | null) => {
    const state = stateRef.current;
    state.activeSessionId = sessionId;
    // Use immediate save to ensure active session is persisted before page unload
    immediateSave();
  }, [immediateSave]);

  const removeSession = useCallback((sessionId: string) => {
    const state = stateRef.current;

    // Remove from sessions list
    state.sessions = state.sessions.filter((s) => s.id !== sessionId);

    // Remove session state
    delete state.sessionStates[sessionId];

    // Clear active if it was this session
    if (state.activeSessionId === sessionId) {
      state.activeSessionId = state.sessions.length > 0 ? state.sessions[0]!.id : null;
    }

    // Use immediate save for deletion (critical operation)
    immediateSave();
  }, [immediateSave]);

  const hasSession = useCallback((sessionId: string): boolean => {
    const state = stateRef.current;
    return state.sessions.some((s) => s.id === sessionId);
  }, []);

  const getSessionIds = useCallback((): string[] => {
    const state = stateRef.current;
    return state.sessions.map((s) => s.id);
  }, []);

  return {
    loadSessions,
    loadSessionState,
    saveSession,
    saveSessionState,
    setActiveSession,
    removeSession,
    hasSession,
    getSessionIds,
  };
}
