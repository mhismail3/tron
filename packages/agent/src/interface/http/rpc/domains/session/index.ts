/**
 * @fileoverview Session domain - Session management
 *
 * Handles session creation, resumption, listing, deletion, and forking.
 */

// Re-export handler factory
export { createSessionHandlers } from '@interface/rpc/handlers/session.handler.js';

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
} from '@interface/rpc/types/session.js';
