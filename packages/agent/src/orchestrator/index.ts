/**
 * @fileoverview Orchestrator Module Exports
 *
 * This module provides components for event orchestration:
 *
 * ## Core Components
 *
 * - **EventPersister**: Encapsulated linearized event persistence
 *   - Handles promise chaining for linearized writes
 *   - Each session gets its own EventPersister instance
 *
 * - **TurnManager**: Turn lifecycle management
 *   - Wraps TurnContentTracker
 *   - Builds message.assistant content blocks
 *   - Handles interrupted content for persistence
 *
 * - **Handlers**: Encapsulated special case handling
 *   - PlanModeHandler: Plan mode state management
 *   - InterruptHandler: Interrupted session content
 *   - CompactionHandler: Context compaction events
 *   - ContextClearHandler: Context clearing events
 *
 * - **SessionReconstructor**: Session state reconstruction
 *   - Reconstructs plan mode, turn count, interrupt status from events
 *   - Handles reset points (compaction, context clear)
 *
 * - **SessionContext**: Per-session state encapsulation
 *   - Wraps EventPersister, TurnManager, PlanModeHandler
 *   - Clean interface for orchestrator operations
 *   - State restoration via SessionReconstructor
 *
 * ## Supporting Components
 *
 * - **turn-content-tracker**: Turn content accumulation
 * - **types**: Type definitions
 * - **worktree-ops**: Worktree operations
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
  type NormalizedTokenUsage,
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

// Session state reconstruction (Phase 4)
export {
  SessionReconstructor,
  createSessionReconstructor,
  type ReconstructedState,
} from './session-reconstructor.js';

// Session context (Phase 5)
export {
  SessionContext,
  createSessionContext,
  type SessionContextConfig,
} from './session-context.js';

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

// Sub-agent operations (Phase 1 extraction)
export {
  SubagentOperations,
  createSubagentOperations,
  type SubagentOperationsConfig,
  type SpawnSubagentResult,
  type SpawnTmuxAgentResult,
  type QuerySubagentResult,
  type WaitForSubagentsResult,
} from './subagent-ops.js';

// Agent event handling (Phase 2 extraction)
export {
  AgentEventHandler,
  createAgentEventHandler,
  type AgentEventHandlerConfig,
} from './agent-event-handler.js';

// Skill loading (Phase 3 extraction)
export {
  SkillLoader,
  createSkillLoader,
  type SkillLoaderConfig,
  type SkillLoadContext,
} from './skill-loader.js';

// Session management (Phase 5 extraction)
export {
  SessionManager,
  createSessionManager,
  type SessionManagerConfig,
} from './session-manager.js';

// Context operations (Phase 6 extraction)
export {
  ContextOps,
  createContextOps,
  type ContextOpsConfig,
} from './context-ops.js';

// Agent factory (Phase 7 extraction)
export {
  AgentFactory,
  createAgentFactory,
  type AgentFactoryConfig,
} from './agent-factory.js';

// Auth provider (Phase 8 extraction)
export {
  AuthProvider,
  createAuthProvider,
  type AuthProviderConfig,
} from './auth-provider.js';

// Agent runner (extracted from runAgent god method)
export {
  AgentRunner,
  createAgentRunner,
  type AgentRunnerConfig,
} from './agent-runner.js';

// Model controller (extracted model switching)
export {
  ModelController,
  createModelController,
  type ModelControllerConfig,
  type ModelSwitchResult,
} from './model-controller.js';
