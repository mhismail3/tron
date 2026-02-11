/**
 * @fileoverview Session Event Union Type
 *
 * Union of all session event types.
 */

import type { SessionStartEvent, SessionEndEvent, SessionForkEvent } from './session.js';
import type { UserMessageEvent, AssistantMessageEvent, SystemMessageEvent } from './message.js';
import type { ToolCallEvent, ToolResultEvent } from './tool.js';
import type { StreamTurnStartEvent, StreamTurnEndEvent, StreamTextDeltaEvent, StreamThinkingDeltaEvent } from './streaming.js';
import type { ConfigModelSwitchEvent, ConfigPromptUpdateEvent, ConfigReasoningLevelEvent } from './config.js';
import type { MessageDeletedEvent } from './message-ops.js';
import type { CompactBoundaryEvent, CompactSummaryEvent } from './compact.js';
import type { ContextClearedEvent } from './context.js';
import type { MetadataUpdateEvent, MetadataTagEvent } from './metadata.js';
import type { FileReadEvent, FileWriteEvent, FileEditEvent } from './file.js';
import type { WorktreeAcquiredEvent, WorktreeCommitEvent, WorktreeReleasedEvent, WorktreeMergedEvent } from './worktree.js';
import type { ErrorAgentEvent, ErrorToolEvent, ErrorProviderEvent } from './error.js';
import type { RulesLoadedEvent, RulesIndexedEvent } from './rules.js';
import type { SubagentSpawnedEvent, SubagentStatusUpdateEvent, SubagentCompletedEvent, SubagentFailedEvent } from './subagent.js';
import type { TodoWriteEvent } from './todo.js';
import type { TurnFailedEvent } from './turn.js';
import type { SkillAddedEvent, SkillRemovedEvent } from './skill.js';
import type {
  HookTriggeredEvent,
  HookCompletedEvent,
  HookBackgroundStartedEvent,
  HookBackgroundCompletedEvent,
} from './hook.js';
import type { MemoryLedgerEvent } from './memory.js';

// =============================================================================
// Union Type
// =============================================================================

export type SessionEvent =
  // Session lifecycle
  | SessionStartEvent
  | SessionEndEvent
  | SessionForkEvent
  // Messages
  | UserMessageEvent
  | AssistantMessageEvent
  | SystemMessageEvent
  // Tools
  | ToolCallEvent
  | ToolResultEvent
  // Streaming
  | StreamTurnStartEvent
  | StreamTurnEndEvent
  | StreamTextDeltaEvent
  | StreamThinkingDeltaEvent
  // Config
  | ConfigModelSwitchEvent
  | ConfigPromptUpdateEvent
  | ConfigReasoningLevelEvent
  // Message operations
  | MessageDeletedEvent
  // Compaction
  | CompactBoundaryEvent
  | CompactSummaryEvent
  // Context clearing
  | ContextClearedEvent
  // Metadata
  | MetadataUpdateEvent
  | MetadataTagEvent
  // Files
  | FileReadEvent
  | FileWriteEvent
  | FileEditEvent
  // Worktree
  | WorktreeAcquiredEvent
  | WorktreeCommitEvent
  | WorktreeReleasedEvent
  | WorktreeMergedEvent
  // Rules
  | RulesLoadedEvent
  | RulesIndexedEvent
  // Subagents
  | SubagentSpawnedEvent
  | SubagentStatusUpdateEvent
  | SubagentCompletedEvent
  | SubagentFailedEvent
  // Todos
  | TodoWriteEvent
  // Skills
  | SkillAddedEvent
  | SkillRemovedEvent
  // Errors
  | ErrorAgentEvent
  | ErrorToolEvent
  | ErrorProviderEvent
  // Turn events
  | TurnFailedEvent
  // Hook events
  | HookTriggeredEvent
  | HookCompletedEvent
  | HookBackgroundStartedEvent
  | HookBackgroundCompletedEvent
  // Memory events
  | MemoryLedgerEvent;
