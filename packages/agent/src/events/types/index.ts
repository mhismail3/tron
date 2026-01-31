/**
 * @fileoverview Events Types Index
 *
 * Re-exports all event types from domain-specific files.
 * This file provides backward compatibility for imports from './types'.
 *
 * Design principles:
 * 1. Every event is immutable - never modified after creation
 * 2. Events form a tree via parentId chains
 * 3. Sessions are pointers to head events
 * 4. State is reconstructed by replaying events
 *
 * ## Persisted vs Streaming Events
 *
 * All EventType values defined here ARE persisted to the EventStore.
 * However, there are also WebSocket-only streaming events that are NOT defined
 * here because they are ephemeral:
 *
 * WEBSOCKET-ONLY (NOT persisted, defined in rpc/types.ts):
 * - `agent.text_delta` - Real-time text chunks, accumulated into message.assistant
 * - `agent.tool_start/end` - Tool progress, consolidated into tool.call/result
 * - `agent.turn_start/end` - UI lifecycle, stream.turn_* is the persisted form
 *
 * The `stream.*` event types below ARE persisted for reconstruction but contain
 * boundary/metadata info, not the high-frequency delta content itself.
 */

// =============================================================================
// Branded Types (both types and value constructors)
// =============================================================================

// Re-export both types and value constructors in a single export
// This avoids duplicate identifier errors while preserving both namespaces
export { EventId, SessionId, WorkspaceId, BranchId } from './branded.js';

// =============================================================================
// Base Types
// =============================================================================

export type { EventType, BaseEvent } from './base.js';

// =============================================================================
// Token Usage
// =============================================================================

export type { TokenUsage } from './token-usage.js';

// =============================================================================
// Session Events
// =============================================================================

export type {
  SessionStartEvent,
  SessionEndEvent,
  SessionForkEvent,
  SessionBranchEvent,
} from './session.js';

// =============================================================================
// Message Events
// =============================================================================

export type {
  ContentBlock,
  UserMessageEvent,
  AssistantMessageEvent,
  SystemMessageEvent,
} from './message.js';

// =============================================================================
// Tool Events
// =============================================================================

export type { ToolCallEvent, ToolResultEvent } from './tool.js';

// =============================================================================
// Streaming Events
// =============================================================================

export type {
  NormalizedTokenUsage,
  StreamTurnStartEvent,
  StreamTurnEndEvent,
  StreamTextDeltaEvent,
  StreamThinkingDeltaEvent,
} from './streaming.js';

// =============================================================================
// Config Events
// =============================================================================

export type {
  ConfigModelSwitchEvent,
  ConfigPromptUpdateEvent,
  ConfigReasoningLevelEvent,
} from './config.js';

// =============================================================================
// Message Operations Events
// =============================================================================

export type { MessageDeletedEvent } from './message-ops.js';

// =============================================================================
// Compaction Events
// =============================================================================

export type { CompactBoundaryEvent, CompactSummaryEvent } from './compact.js';

// =============================================================================
// Context Events
// =============================================================================

export type { ContextClearedEvent } from './context.js';

// =============================================================================
// Metadata Events
// =============================================================================

export type { MetadataUpdateEvent, MetadataTagEvent } from './metadata.js';

// =============================================================================
// File Events
// =============================================================================

export type { FileReadEvent, FileWriteEvent, FileEditEvent } from './file.js';

// =============================================================================
// Worktree Events
// =============================================================================

export type {
  WorktreeAcquiredEvent,
  WorktreeCommitEvent,
  WorktreeReleasedEvent,
  WorktreeMergedEvent,
} from './worktree.js';

// =============================================================================
// Error Events
// =============================================================================

export type { ErrorAgentEvent, ErrorToolEvent, ErrorProviderEvent } from './error.js';

// =============================================================================
// Rules Events
// =============================================================================

export type {
  RulesLevel,
  RulesFileInfo,
  RulesLoadedPayload,
  RulesLoadedEvent,
} from './rules.js';

// =============================================================================
// Plan Mode Events
// =============================================================================

export type {
  PlanModeEnteredEvent,
  PlanModeExitedEvent,
  PlanCreatedEvent,
} from './plan.js';

// =============================================================================
// Subagent Events
// =============================================================================

export type {
  SubagentSpawnType,
  SubagentSpawnedEvent,
  SubagentStatusUpdateEvent,
  SubagentCompletedEvent,
  SubagentFailedEvent,
} from './subagent.js';

// =============================================================================
// Todo Events
// =============================================================================

export type { TodoItemPayload, TodoWriteEvent } from './todo.js';

// =============================================================================
// Turn Events
// =============================================================================

export type { TurnFailedEvent } from './turn.js';

// =============================================================================
// Hook Events
// =============================================================================

export type {
  HookTriggeredEvent,
  HookCompletedEvent,
  HookBackgroundStartedEvent,
  HookBackgroundCompletedEvent,
} from './hook.js';

// =============================================================================
// Union Type
// =============================================================================

export type { SessionEvent } from './union.js';

// =============================================================================
// Type Guards
// =============================================================================

export {
  isSessionStartEvent,
  isSessionEndEvent,
  isSessionForkEvent,
  isUserMessageEvent,
  isAssistantMessageEvent,
  isToolCallEvent,
  isToolResultEvent,
  isMessageEvent,
  isStreamingEvent,
  isErrorEvent,
  isWorktreeEvent,
  isWorktreeAcquiredEvent,
  isWorktreeCommitEvent,
  isWorktreeReleasedEvent,
  isWorktreeMergedEvent,
  isRulesLoadedEvent,
  isContextClearedEvent,
  isConfigReasoningLevelEvent,
  isMessageDeletedEvent,
  isConfigEvent,
  isPlanModeEnteredEvent,
  isPlanModeExitedEvent,
  isPlanCreatedEvent,
  isPlanEvent,
  isSubagentSpawnedEvent,
  isSubagentStatusUpdateEvent,
  isSubagentCompletedEvent,
  isSubagentFailedEvent,
  isSubagentEvent,
  isTodoWriteEvent,
  isTodoEvent,
  isTurnFailedEvent,
  isTurnEvent,
  isHookTriggeredEvent,
  isHookCompletedEvent,
  isHookBackgroundStartedEvent,
  isHookBackgroundCompletedEvent,
  isHookEvent,
} from './type-guards.js';

// =============================================================================
// State Types
// =============================================================================

export type {
  CreateEventInput,
  Message,
  MessageWithEventId,
  SessionState,
  SessionMetadata,
  Branch,
  TreeNode,
  TreeNodeCompact,
  SearchResult,
  SessionSummary,
  Workspace,
} from './state.js';
