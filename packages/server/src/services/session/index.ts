/**
 * @fileoverview Session Service
 *
 * Provides session lifecycle management with a clean interface.
 * Wraps the SessionManager implementation with a formal service contract.
 *
 * ## Responsibilities
 * - Session creation, resumption, and termination
 * - Session listing and queries
 * - Fork operations
 * - Inactive session cleanup
 *
 * ## Usage
 * ```typescript
 * const sessionService = createSessionService(deps);
 * const session = await sessionService.createSession({ workingDirectory: '/path' });
 * await sessionService.endSession(session.sessionId);
 * ```
 */
import {
  SessionManager,
  createSessionManager,
  type SessionManagerConfig,
} from '../../orchestrator/session-manager.js';
import type {
  ActiveSession,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from '../../orchestrator/types.js';

// =============================================================================
// Service Interface
// =============================================================================

/**
 * Session service interface - clean contract for session lifecycle management.
 */
export interface SessionService {
  /**
   * Create a new session.
   * @param options - Session configuration
   * @returns Session info including ID, working directory, and model
   */
  createSession(options: CreateSessionOptions): Promise<SessionInfo>;

  /**
   * Resume an existing session.
   * Loads session state from EventStore and reconstructs agent.
   * @param sessionId - Session ID to resume
   * @returns Session info
   */
  resumeSession(sessionId: string): Promise<SessionInfo>;

  /**
   * End a session, persisting final state and releasing resources.
   * @param sessionId - Session ID to end
   * @param options - Optional merge configuration for worktree
   */
  endSession(sessionId: string, options?: EndSessionOptions): Promise<void>;

  /**
   * Get session info by ID.
   * @param sessionId - Session ID
   * @returns Session info or null if not found
   */
  getSession(sessionId: string): Promise<SessionInfo | null>;

  /**
   * List sessions with optional filters.
   * @param options - Filter options
   * @returns Array of session info
   */
  listSessions(options: ListSessionsOptions): Promise<SessionInfo[]>;

  /**
   * Get an active (in-memory) session.
   * @param sessionId - Session ID
   * @returns Active session or undefined if not in memory
   */
  getActiveSession(sessionId: string): ActiveSession | undefined;

  /**
   * Check if a session was interrupted.
   * @param sessionId - Session ID
   * @returns True if session was interrupted
   */
  wasSessionInterrupted(sessionId: string): Promise<boolean>;

  /**
   * Fork a session from a specific event.
   * Creates a new session branching from the specified point.
   * @param sessionId - Source session ID
   * @param fromEventId - Optional event ID to fork from (defaults to head)
   * @returns Fork result with new session ID
   */
  forkSession(sessionId: string, fromEventId?: string): Promise<ForkResult>;

  /**
   * Clean up inactive sessions that have exceeded the threshold.
   * @param inactiveThresholdMs - Threshold in milliseconds (default: 30 minutes)
   */
  cleanupInactiveSessions(inactiveThresholdMs?: number): Promise<void>;
}

// =============================================================================
// Service Options Types
// =============================================================================

export interface EndSessionOptions {
  /** Branch to merge worktree changes to */
  mergeTo?: string;
  /** Merge strategy for worktree */
  mergeStrategy?: 'merge' | 'rebase' | 'squash';
  /** Commit message for worktree changes */
  commitMessage?: string;
}

export interface ListSessionsOptions {
  /** Filter by working directory */
  workingDirectory?: string;
  /** Maximum number of sessions to return */
  limit?: number;
  /** Only return active (in-memory) sessions */
  activeOnly?: boolean;
}

// =============================================================================
// Service Dependencies
// =============================================================================

/**
 * Dependencies required by SessionService.
 * These are injected at creation time.
 */
export type SessionServiceDeps = SessionManagerConfig;

// =============================================================================
// Service Implementation
// =============================================================================

/**
 * SessionService implementation wrapping SessionManager.
 * Provides a clean interface while delegating to the existing implementation.
 */
class SessionServiceImpl implements SessionService {
  private manager: SessionManager;

  constructor(deps: SessionServiceDeps) {
    this.manager = createSessionManager(deps);
  }

  async createSession(options: CreateSessionOptions): Promise<SessionInfo> {
    return this.manager.createSession(options);
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    return this.manager.resumeSession(sessionId);
  }

  async endSession(sessionId: string, options?: EndSessionOptions): Promise<void> {
    return this.manager.endSession(sessionId, options);
  }

  async getSession(sessionId: string): Promise<SessionInfo | null> {
    return this.manager.getSession(sessionId);
  }

  async listSessions(options: ListSessionsOptions): Promise<SessionInfo[]> {
    return this.manager.listSessions(options);
  }

  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.manager.getActiveSession(sessionId);
  }

  async wasSessionInterrupted(sessionId: string): Promise<boolean> {
    return this.manager.wasSessionInterrupted(sessionId);
  }

  async forkSession(sessionId: string, fromEventId?: string): Promise<ForkResult> {
    return this.manager.forkSession(sessionId, fromEventId);
  }

  async cleanupInactiveSessions(inactiveThresholdMs?: number): Promise<void> {
    return this.manager.cleanupInactiveSessions(inactiveThresholdMs);
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a new SessionService instance.
 * @param deps - Service dependencies
 * @returns SessionService instance
 */
export function createSessionService(deps: SessionServiceDeps): SessionService {
  return new SessionServiceImpl(deps);
}

// =============================================================================
// Re-exports
// =============================================================================

// Re-export types for consumers
export type {
  ActiveSession,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from '../../orchestrator/types.js';
