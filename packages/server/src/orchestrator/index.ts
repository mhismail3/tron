/**
 * @fileoverview Orchestrator Module Exports
 *
 * This module provides components for event orchestration:
 *
 * ## New Modular Components (Phase 1+)
 *
 * - **EventPersister**: Encapsulated linearized event persistence
 *   - Replaces direct use of appendPromiseChain/pendingHeadEventId
 *   - Each session gets its own EventPersister instance
 *
 * ## Existing Components
 *
 * - **event-linearizer**: Legacy functions (will be deprecated)
 * - **turn-content-tracker**: Turn content accumulation
 * - **types**: Type definitions
 * - **worktree-ops**: Worktree operations
 *
 * ## Migration Path
 *
 * The existing event-store-orchestrator.ts uses the legacy event-linearizer
 * functions directly. As we extract more modules (TurnManager, Handlers, etc.),
 * the orchestrator will migrate to using these encapsulated components.
 */

// =============================================================================
// New Modular Components
// =============================================================================

// Event persistence (Phase 1)
export {
  EventPersister,
  createEventPersister,
  type EventPersisterConfig,
  type AppendRequest,
} from './event-persister.js';

// =============================================================================
// Existing Components
// =============================================================================

// Turn content tracking
export { TurnContentTracker } from './turn-content-tracker.js';

// Types
export type {
  EventStoreOrchestratorConfig,
  BrowserConfig,
  WorktreeInfo,
  ActiveSession,
  FileAttachment,
  PromptSkillRef,
  LoadedSkillContent,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from './types.js';

// Worktree operations
export {
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './worktree-ops.js';

// Legacy linearizer (for backward compatibility during migration)
export {
  appendEventLinearized,
  appendEventLinearizedAsync,
  flushPendingEvents,
  flushAllPendingEvents,
} from './event-linearizer.js';
