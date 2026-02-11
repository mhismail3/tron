/**
 * @fileoverview Main entry point for @tron/core
 *
 * Tron Core: Agent loop, memory, hooks, tools, and providers
 *
 * This package provides the foundational components for building
 * the Tron coding agent system.
 */

// Re-export all types
export * from './core/types/index.js';

// Re-export settings (must be early for other modules to use)
export * from './infrastructure/settings/index.js';

// Feature flags are now exported through settings module

// Re-export logging
export * from './infrastructure/logging/index.js';

// Re-export auth
export * from './infrastructure/auth/index.js';

// Re-export providers
export * from './llm/providers/index.js';

// Re-export tools
export * from './capabilities/tools/index.js';

// Memory types are now exported through types module

// Re-export hooks
export * from './capabilities/extensions/hooks/index.js';

// Re-export agent
export * from './runtime/agent/index.js';

// Re-export RPC
export * from './interface/rpc/index.js';

// Re-export session
export * from './platform/session/index.js';

// Re-export productivity
export * from './platform/productivity/index.js';

// Re-export commands
export * from './capabilities/extensions/commands/index.js';

// Tmux support is now exported through session module

// Re-export context loading
export * from './context/index.js';

// Re-export skills
export * from './capabilities/extensions/skills/index.js';

// Subagent tracker is now exported through tools module

// Re-export events (Event Sourcing system)
export * from './infrastructure/events/index.js';

// Task management types are available via @capabilities/tasks/index.js
// Not re-exported from root to avoid naming conflict with platform/productivity Task

// Re-export guardrails
export * from './capabilities/guardrails/index.js';

// Re-export UI (RenderAppUI component types and schema)
export * from './interface/ui/index.js';

// Re-export utilities (error handling, clipboard, etc.)
export * from './core/utils/index.js';

// Re-export usage tracking (tokens, costs)
export * from './infrastructure/usage/index.js';

// Re-export server components
export { TronServer, type TronServerConfig } from './interface/server.js';
export { EventStoreOrchestrator } from './runtime/orchestrator/persistence/event-store-orchestrator.js';
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from './runtime/orchestrator/persistence/event-store-orchestrator.js';

// Re-export gateway components
export * from './interface/gateway/index.js';


// Re-export orchestrator modules (explicit to avoid type conflicts)
export {
  EventPersister,
  createEventPersister,
  TurnManager,
  createTurnManager,
  TurnContentTracker,
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
  type TokenRecord,
  type TokenSource,
  type ComputedTokens,
  type TokenMeta,
  type TokenState,
  type AccumulatedTokens,
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
} from './runtime/orchestrator/index.js';

// Version info (re-exported from constants to avoid circular deps)
export { VERSION, NAME } from './core/constants.js';
