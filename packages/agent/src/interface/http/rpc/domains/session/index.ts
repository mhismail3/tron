/**
 * @fileoverview Session domain - Session management
 *
 * Handles session creation, resumption, listing, deletion, and forking.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleSessionCreate,
  handleSessionResume,
  handleSessionList,
  handleSessionDelete,
  handleSessionFork,
  createSessionHandlers,
} from '../../../../rpc/handlers/session.handler.js';

// Re-export types
export type {
  SessionCreateParams,
  SessionCreateResult,
  SessionResumeParams,
  SessionResumeResult,
  SessionListParams,
  SessionListResult,
  SessionDeleteParams,
  SessionDeleteResult,
  SessionForkParams,
  SessionForkResult,
} from '../../../../rpc/types/session.js';
