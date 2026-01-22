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

// Re-export feature flags
export * from './features/index.js';

// Re-export logging
export * from './logging/index.js';

// Re-export auth
export * from './auth/index.js';

// Re-export providers
export * from './providers/index.js';

// Re-export tools
export * from './tools/index.js';

// Re-export memory
export * from './memory/index.js';

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

// Re-export tmux support
export * from './tmux/index.js';

// Re-export context loading
export * from './context/index.js';

// Re-export skills
export * from './skills/index.js';

// Re-export subagents
export * from './subagents/index.js';

// Re-export events (Event Sourcing system)
export * from './events/index.js';

// Re-export todos (Task management)
export * from './todos/index.js';

// Re-export guardrails
export * from './guardrails/index.js';

// Re-export UI (RenderAppUI component types and schema)
export * from './ui/index.js';

// Re-export artifacts (canvas persistence)
export * from './artifacts/index.js';

// Re-export utilities (error handling, clipboard, etc.)
export * from './utils/index.js';

// Re-export usage tracking (tokens, costs)
export * from './usage/index.js';

// Re-export server components
export { TronServer, type TronServerConfig } from './server.js';
export { EventStoreOrchestrator } from './event-store-orchestrator.js';
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from './event-store-orchestrator.js';

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

// Version info
export const VERSION = '0.1.0';
export const NAME = 'tron';
