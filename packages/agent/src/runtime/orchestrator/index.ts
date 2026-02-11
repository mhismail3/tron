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
 * - **SessionReconstructor**: Session state reconstruction
 *   - Reconstructs turn count, interrupt status from events
 *   - Handles reset points (compaction, context clear)
 *
 * - **SessionContext**: Per-session state encapsulation
 *   - Wraps EventPersister, TurnManager
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
// Event Persistence (organized in persistence/ subfolder)
// =============================================================================

// Event persistence
export {
  EventPersister,
  createEventPersister,
  type EventPersisterConfig,
  type AppendRequest,
} from './persistence/index.js';

// Event store orchestrator
export { EventStoreOrchestrator } from './persistence/index.js';

// =============================================================================
// Turn Execution (organized in turn/ subfolder)
// =============================================================================

// Turn lifecycle management
export {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type TextContentBlock,
  type ThinkingContentBlock,
  type ToolUseContentBlock,
  type AssistantContentBlock,
  type ToolResultBlock,
  type EndTurnResult,
} from './turn/index.js';

// Turn content tracking
export { TurnContentTracker } from './turn/index.js';

// Token tracking is now in @infrastructure/tokens - re-export for convenience
export type {
  TokenRecord,
  TokenSource,
  ComputedTokens,
  TokenMeta,
  TokenState,
  AccumulatedTokens,
} from '@infrastructure/tokens/index.js';

// Content block building utilities (extracted from TurnContentTracker)
export {
  buildPreToolContentBlocks,
  buildInterruptedContentBlocks,
  buildThinkingBlock,
  buildToolUseBlock,
  buildToolResultBlock,
  type ContentSequenceItem,
  type ToolCallData,
  type PreToolContentBlock,
  type InterruptedContentBlocks,
  type ThinkingBlock,
  type ToolUseBlock,
  type ToolUseMeta,
  type ToolResultMeta,
} from './turn/index.js';

// Agent event handling
export {
  AgentEventHandler,
  createAgentEventHandler,
  type AgentEventHandlerConfig,
} from './turn/index.js';

// =============================================================================
// Session Lifecycle (organized in session/ subfolder)
// =============================================================================

// Session state reconstruction
export {
  SessionReconstructor,
  createSessionReconstructor,
  type ReconstructedState,
} from './session/index.js';

// Session context
export {
  SessionContext,
  createSessionContext,
  type SessionContextConfig,
} from './session/index.js';

// Session management
export {
  SessionManager,
  createSessionManager,
  type SessionManagerConfig,
} from './session/index.js';

// Auth provider
export {
  AuthProvider,
  createAuthProvider,
  type AuthProviderConfig,
} from './session/index.js';

// =============================================================================
// Feature Controllers (organized in controllers/ subfolder)
// =============================================================================

// Model switching
export {
  ModelController,
  createModelController,
  type ModelControllerConfig,
  type ModelSwitchResult,
} from './controllers/index.js';

// Push notifications
export {
  NotificationController,
  createNotificationController,
  type NotificationControllerConfig,
  type NotificationPayload,
} from './controllers/index.js';


// Embedding and vector search
export {
  EmbeddingController,
  createEmbeddingController,
  type EmbeddingControllerConfig,
} from './controllers/index.js';

// =============================================================================
// Domain Operations (organized in operations/ subfolder)
// =============================================================================

// Context operations
export {
  ContextOps,
  createContextOps,
  type ContextOpsConfig,
} from './operations/index.js';

// Sub-agent operations
export {
  SubagentOperations,
  createSubagentOperations,
  type SubagentOperationsConfig,
  type SpawnSubagentResult,
  type SpawnTmuxAgentResult,
  type QuerySubagentResult,
  type WaitForSubagentsResult,
} from './operations/index.js';

// Worktree operations
export {
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './operations/index.js';

// Skill loading
export {
  SkillLoader,
  createSkillLoader,
  type SkillLoaderConfig,
  type SkillLoadContext,
} from './operations/index.js';

// =============================================================================
// Existing Components
// =============================================================================

// Types
export type {
  EventStoreOrchestratorConfig,
  BrowserConfig,
  WorktreeInfo,
  SessionIdentity,
  SessionRuntime,
  SessionTracking,
  SessionMetadata,
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

// Agent factory (Phase 7 extraction)
export {
  AgentFactory,
  createAgentFactory,
  type AgentFactoryConfig,
} from './agent-factory.js';

// Agent runner (extracted from runAgent god method)
export {
  AgentRunner,
  createAgentRunner,
  type AgentRunnerConfig,
} from './agent-runner.js';
