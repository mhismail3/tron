/**
 * @fileoverview Event-Sourced Session Tree System
 *
 * Public exports for the event store module.
 *
 * NOTE: Some types are prefixed with "Event" to avoid conflicts with
 * other modules in the core package (e.g., EventSearchOptions vs SearchOptions).
 */

// Types - ID types (branded)
export {
  EventId,
  SessionId,
  WorkspaceId,
  BranchId,
} from './types.js';

// Types - Event types (using aliases to avoid conflicts)
export {
  type EventType,
  type BaseEvent,
  // Rename to avoid conflict with session/types.ts SessionEvent
  type SessionEvent as TronSessionEvent,
  type SessionStartEvent,
  type SessionEndEvent,
  type SessionForkEvent,
  type UserMessageEvent,
  type AssistantMessageEvent,
  type SystemMessageEvent,
  type ToolCallEvent,
  type ToolResultEvent,
  type StreamTextDeltaEvent,
  type StreamThinkingDeltaEvent,
  type StreamTurnStartEvent,
  type StreamTurnEndEvent,
  type ConfigModelSwitchEvent,
  type ConfigPromptUpdateEvent,
  type CompactBoundaryEvent,
  type CompactSummaryEvent,
  type MetadataUpdateEvent,
  type MetadataTagEvent,
  type FileReadEvent,
  type FileWriteEvent,
  type FileEditEvent,
  type ErrorAgentEvent,
  type ErrorToolEvent,
  type ErrorProviderEvent,
  // Worktree events
  type WorktreeAcquiredEvent,
  type WorktreeCommitEvent,
  type WorktreeReleasedEvent,
  type WorktreeMergedEvent,
  // Worktree type guards
  isWorktreeEvent,
  isWorktreeAcquiredEvent,
  isWorktreeCommitEvent,
  isWorktreeReleasedEvent,
  isWorktreeMergedEvent,
  // Rules events
  type RulesLevel,
  type RulesFileInfo,
  type RulesLoadedPayload,
  type RulesLoadedEvent,
  isRulesLoadedEvent,
  // Subagent events
  type SubagentSpawnType,
  type SubagentSpawnedEvent,
  type SubagentStatusUpdateEvent,
  type SubagentCompletedEvent,
  type SubagentFailedEvent,
  isSubagentSpawnedEvent,
  isSubagentStatusUpdateEvent,
  isSubagentCompletedEvent,
  isSubagentFailedEvent,
  isSubagentEvent,
} from './types.js';

// Types - State types (with prefixes to avoid conflicts)
export {
  type Workspace as EventWorkspace,
  type Branch as EventBranch,
  type SessionState as EventSessionState,
  // Message and TokenUsage are also in core types - use prefixed versions
  type Message as EventMessage,
  type TokenUsage as EventTokenUsage,
  // Rename to avoid conflict with memory SearchResult
  type SearchResult as EventSearchResult,
  type TreeNode as EventTreeNode,
} from './types.js';

// EventStore
export {
  EventStore,
  type EventStoreConfig,
  // Rename to avoid conflict with session CreateSessionOptions
  type CreateSessionOptions as EventCreateSessionOptions,
  type CreateSessionResult as EventCreateSessionResult,
  type AppendEventOptions,
  type ForkOptions as EventForkOptions,
  type ForkResult as EventForkResult,
  // Rename to avoid conflict with memory SearchOptions
  type SearchOptions as EventSearchOptions,
} from './event-store.js';

// Message reconstruction (internal utility, exposed for testing)
export {
  reconstructFromEvents,
  type ReconstructionResult,
} from './message-reconstructor.js';

// SQLite Event Store (for advanced use cases)
// Uses modular facade architecture
export {
  SQLiteEventStore,
  createSQLiteEventStore,
  type SQLiteBackendConfig,
  type CreateWorkspaceOptions,
  type SessionRow,
  type CreateBranchOptions,
  type BranchRow,
  // Rename to avoid conflict with session ListSessionsOptions
  type ListSessionsOptions as EventListSessionsOptions,
  type IncrementCountersOptions,
} from './sqlite/facade.js';

// Event factory for consistent event construction
export {
  createEventFactory,
  type EventFactory,
  type EventFactoryOptions,
  type SessionStartOptions,
  type SessionForkOptions,
  type GenericEventOptions,
} from './event-factory.js';

// Event chain builder for sequential appends
export { EventChainBuilder } from './event-chain-builder.js';
