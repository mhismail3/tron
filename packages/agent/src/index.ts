/**
 * @fileoverview Main entry point for @tron/core
 *
 * Tron Core: Agent loop, memory, hooks, tools, and providers
 *
 * This package provides the foundational components for building
 * the Tron coding agent system.
 */

// Re-export all types
export * from './types/index.js';

// Re-export settings (must be early for other modules to use)
export * from './settings/index.js';

// Feature flags are now exported through settings module

// Re-export logging
export * from './logging/index.js';

// Re-export auth
export * from './auth/index.js';

// Re-export providers
export * from './providers/index.js';

// Re-export tools
export * from './tools/index.js';

// Memory types are now exported through types module

// Re-export hooks
export * from './hooks/index.js';

// Re-export agent
export * from './agent/index.js';

// Re-export RPC
export * from './rpc/index.js';

// Re-export session
export * from './session/index.js';

// Re-export productivity
export * from './productivity/index.js';

// Re-export commands
export * from './commands/index.js';

// Tmux support is now exported through session module

// Re-export context loading
export * from './context/index.js';

// Re-export skills
export * from './skills/index.js';

// Subagent tracker is now exported through tools module

// Re-export events (Event Sourcing system)
export * from './events/index.js';

// Re-export todos (Task management)
export * from './todos/index.js';

// Re-export guardrails
export * from './guardrails/index.js';

// Re-export UI (RenderAppUI component types and schema)
export * from './ui/index.js';

// Re-export utilities (error handling, clipboard, etc.)
export * from './utils/index.js';

// Re-export usage tracking (tokens, costs)
export * from './usage/index.js';

// Re-export server components
export { TronServer, type TronServerConfig } from './server.js';
export { EventStoreOrchestrator } from './orchestrator/event-store-orchestrator.js';
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from './orchestrator/event-store-orchestrator.js';

// Re-export gateway components
export * from './gateway/index.js';

// Re-export services (explicit to avoid type conflicts)
export {
  createSessionService,
  createContextService,
  type SessionService,
  type SessionServiceDeps,
  type EndSessionOptions,
  type ContextService,
  type ContextServiceDeps,
  type CompactionOptions,
  type TurnValidationOptions,
  type ClearContextResult,
  type OrchestrationService,
} from './services/index.js';

// Re-export orchestrator modules (explicit to avoid type conflicts)
export {
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

// Version info (re-exported from constants to avoid circular deps)
export { VERSION, NAME } from './constants.js';
