/**
 * @fileoverview Store Module Exports
 *
 * Re-exports all store-related types, functions, and components.
 */

// Types
export type {
  AppState,
  AppAction,
  DisplayMessage,
  MenuId,
  MenuStackEntry,
  SessionSummary,
  ConnectionStatus,
  ConnectionState,
  UIState,
} from './types.js';

// Reducer
export { reducer, initialState, createInitialState } from './reducer.js';

// Context
export {
  ChatProvider,
  useChatStore,
  useChatState,
  useChatDispatch,
  useChatSelector,
} from './context.js';

// Event DB (IndexedDB event cache)
export {
  EventDB,
  getEventDB,
  type CachedEvent,
  type CachedSession,
  type SyncState,
  type EventTreeNode,
} from './event-db.js';

// Worktree Store
export {
  useWorktreeStore,
  worktreeReducer,
  initialWorktreeState,
  type WorktreeState,
  type WorktreeAction,
  type WorktreeStatus,
  type WorktreeInfo,
  type WorktreeListItem,
  type UseWorktreeStoreReturn,
} from './worktree-store.js';
