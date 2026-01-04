/**
 * @fileoverview React Context for Chat State
 *
 * Provides the chat state and dispatch function to all components
 * via React Context. Uses useReducer for predictable state updates.
 */

import React, { createContext, useContext, useReducer, useMemo, type ReactNode } from 'react';
import { reducer, createInitialState } from './reducer.js';
import type { AppState, AppAction } from './types.js';

// =============================================================================
// Context Types
// =============================================================================

interface ChatContextValue {
  state: AppState;
  dispatch: React.Dispatch<AppAction>;
}

// =============================================================================
// Context
// =============================================================================

const ChatContext = createContext<ChatContextValue | null>(null);

// =============================================================================
// Provider Props
// =============================================================================

interface ChatProviderProps {
  children: ReactNode;
  initialState?: Partial<AppState>;
}

// =============================================================================
// Provider Component
// =============================================================================

export function ChatProvider({ children, initialState: initialStateOverrides }: ChatProviderProps): React.ReactElement {
  const [state, dispatch] = useReducer(
    reducer,
    initialStateOverrides,
    (overrides) => ({
      ...createInitialState(),
      ...overrides,
    })
  );

  const value = useMemo(() => ({ state, dispatch }), [state]);

  return (
    <ChatContext.Provider value={value}>
      {children}
    </ChatContext.Provider>
  );
}

// =============================================================================
// Hook
// =============================================================================

export function useChatStore(): ChatContextValue {
  const context = useContext(ChatContext);

  if (context === null) {
    throw new Error('useChatStore must be used within a ChatProvider');
  }

  return context;
}

// =============================================================================
// Convenience Hooks
// =============================================================================

export function useChatState(): AppState {
  return useChatStore().state;
}

export function useChatDispatch(): React.Dispatch<AppAction> {
  return useChatStore().dispatch;
}

// =============================================================================
// Selector Hook
// =============================================================================

export function useChatSelector<T>(selector: (state: AppState) => T): T {
  const { state } = useChatStore();
  return selector(state);
}

// Alias for convenience
export const useChat = useChatState;
