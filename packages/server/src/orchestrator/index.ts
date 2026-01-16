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
 * - **TurnManager**: Turn lifecycle management (Phase 2)
 *   - Wraps TurnContentTracker
 *   - Builds message.assistant content blocks
 *   - Handles interrupted content for persistence
 *
 * - **Handlers** (Phase 3): Encapsulated special case handling
 *   - PlanModeHandler: Plan mode state management
 *   - InterruptHandler: Interrupted session content
 *   - CompactionHandler: Context compaction events
 *   - ContextClearHandler: Context clearing events
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

// Turn lifecycle management (Phase 2)
export {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type TextContentBlock,
  type ToolUseContentBlock,
  type AssistantContentBlock,
  type ToolResultBlock,
  type EndTurnResult,
} from './turn-manager.js';

// Handlers (Phase 3)
export {
  // Plan Mode
  PlanModeHandler,
  createPlanModeHandler,
  type PlanModeState,
  // Interrupt
  InterruptHandler,
  createInterruptHandler,
  type InterruptContext,
  type InterruptResult,
  // Compaction
  CompactionHandler,
  createCompactionHandler,
  type CompactionContext,
  // Context Clear
  ContextClearHandler,
  createContextClearHandler,
  type ContextClearContext,
  type ClearReason,
} from './handlers/index.js';

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
