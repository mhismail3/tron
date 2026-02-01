/**
 * @fileoverview Dashboard context provider
 */

import React, { createContext, useContext, useReducer, type ReactNode } from 'react';
import { reducer, initialState } from './reducer.js';
import type { DashboardState, DashboardAction } from './types.js';

/**
 * Context value type
 */
interface DashboardContextValue {
  state: DashboardState;
  dispatch: React.Dispatch<DashboardAction>;
}

/**
 * Dashboard context
 */
const DashboardContext = createContext<DashboardContextValue | null>(null);

/**
 * Dashboard provider props
 */
interface DashboardProviderProps {
  children: ReactNode;
  initialState?: Partial<DashboardState>;
}

/**
 * Dashboard context provider
 */
export function DashboardProvider({ children, initialState: customInitial }: DashboardProviderProps) {
  const mergedInitial: DashboardState = {
    ...initialState,
    ...customInitial,
  };

  const [state, dispatch] = useReducer(reducer, mergedInitial);

  return (
    <DashboardContext.Provider value={{ state, dispatch }}>
      {children}
    </DashboardContext.Provider>
  );
}

/**
 * Hook to access dashboard state and dispatch
 */
export function useDashboard(): DashboardContextValue {
  const context = useContext(DashboardContext);
  if (!context) {
    throw new Error('useDashboard must be used within a DashboardProvider');
  }
  return context;
}

/**
 * Hook to access just the dashboard state
 */
export function useDashboardState(): DashboardState {
  const { state } = useDashboard();
  return state;
}

/**
 * Hook to access just the dispatch function
 */
export function useDashboardDispatch(): React.Dispatch<DashboardAction> {
  const { dispatch } = useDashboard();
  return dispatch;
}
