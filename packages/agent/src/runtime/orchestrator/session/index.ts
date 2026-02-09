/**
 * @fileoverview Session Lifecycle Module
 *
 * Components for managing session lifecycle:
 *
 * - SessionManager: Session creation, resumption, and termination
 * - SessionContext: Per-session state encapsulation
 * - SessionReconstructor: State restoration from events
 * - AuthProvider: Authentication credential management
 */

// Session management
export {
  SessionManager,
  createSessionManager,
  type SessionManagerConfig,
} from './session-manager.js';

// Session context (Phase 5)
export {
  SessionContext,
  createSessionContext,
  type SessionContextConfig,
} from './session-context.js';

// Session state reconstruction
export {
  SessionReconstructor,
  createSessionReconstructor,
  type ReconstructedState,
} from './session-reconstructor.js';

// Tracker reconstruction (for session resume)
export {
  TrackerReconstructor,
  createTrackerReconstructor,
  type ReconstructedTrackers,
} from './tracker-reconstructor.js';

// Active session store
export {
  MapActiveSessionStore,
  type ActiveSessionStore,
} from './active-session-store.js';

// Auth provider
export {
  AuthProvider,
  createAuthProvider,
  type AuthProviderConfig,
} from './auth-provider.js';
