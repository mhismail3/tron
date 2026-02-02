/**
 * @fileoverview Runtime module exports
 *
 * The runtime module provides agent execution and orchestration including:
 * - Agent loop and turn execution
 * - Event-sourced orchestration
 * - Session and context services
 *
 * Note: For explicit access to compaction handlers, use:
 * - runtime/agent for AgentCompactionHandler
 * - runtime/orchestrator for CompactionHandler
 */

// Agent module - primary agent implementation
export * from './agent/index.js';

// Orchestrator module - event-sourced session management
// (exports createCompactionHandler which conflicts with agent - use explicit import if needed)
export {
  // Event store orchestrator
  EventStoreOrchestrator,
  type EventStoreOrchestratorConfig,
  type ActiveSession,
  type AgentRunOptions,
  type AgentEvent,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
  // Handlers
  EventPersister,
  createEventPersister,
  TurnManager,
  createTurnManager,
  TurnContentTracker,
  PlanModeHandler,
  createPlanModeHandler,
  InterruptHandler,
  createInterruptHandler,
  CompactionHandler,
  createCompactionHandler,
  ContextClearHandler,
  createContextClearHandler,
  SessionReconstructor,
  createSessionReconstructor,
  SessionContext,
  createSessionContext,
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
  SubagentOperations,
  createSubagentOperations,
  AgentEventHandler,
  createAgentEventHandler,
  SkillLoader,
  createSkillLoader,
  SessionManager,
  createSessionManager,
  ContextOps,
  createContextOps,
  AgentFactory,
  createAgentFactory,
  AuthProvider,
  createAuthProvider,
  // Types
  type EventPersisterConfig,
  type AppendRequest,
  type TextContentBlock,
  type ToolUseContentBlock,
  type AssistantContentBlock,
  type ToolResultBlock,
  type EndTurnResult,
  type NormalizedTokenUsage,
  type PlanModeState,
  type InterruptContext,
  type InterruptResult,
  type CompactionContext,
  type ContextClearContext,
  type ClearReason,
  type ReconstructedState,
  type SessionContextConfig,
  type BrowserConfig,
  type WorktreeInfo,
  type FileAttachment,
  type PromptSkillRef,
  type LoadedSkillContent,
  type SubagentOperationsConfig,
  type AgentEventHandlerConfig,
  type SkillLoaderConfig,
  type SkillLoadContext,
  type SessionManagerConfig,
  type ContextOpsConfig,
  type AgentFactoryConfig,
  type AuthProviderConfig,
} from './orchestrator/index.js';

// Services module
export * from './services/index.js';
