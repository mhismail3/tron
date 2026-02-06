/**
 * @fileoverview Type Guards
 *
 * Type guard functions for narrowing SessionEvent types.
 */

import type { SessionEvent } from './union.js';
import type { SessionStartEvent, SessionEndEvent, SessionForkEvent } from './session.js';
import type { UserMessageEvent, AssistantMessageEvent, SystemMessageEvent } from './message.js';
import type { ToolCallEvent, ToolResultEvent } from './tool.js';
import type { ConfigModelSwitchEvent, ConfigPromptUpdateEvent, ConfigReasoningLevelEvent } from './config.js';
import type { MessageDeletedEvent } from './message-ops.js';
import type { ContextClearedEvent } from './context.js';
import type { WorktreeAcquiredEvent, WorktreeCommitEvent, WorktreeReleasedEvent, WorktreeMergedEvent } from './worktree.js';
import type { ErrorAgentEvent, ErrorToolEvent, ErrorProviderEvent } from './error.js';
import type { RulesLoadedEvent } from './rules.js';
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
// Type Guards
// =============================================================================

export function isSessionStartEvent(event: SessionEvent): event is SessionStartEvent {
  return event.type === 'session.start';
}

export function isSessionEndEvent(event: SessionEvent): event is SessionEndEvent {
  return event.type === 'session.end';
}

export function isSessionForkEvent(event: SessionEvent): event is SessionForkEvent {
  return event.type === 'session.fork';
}

export function isUserMessageEvent(event: SessionEvent): event is UserMessageEvent {
  return event.type === 'message.user';
}

export function isAssistantMessageEvent(event: SessionEvent): event is AssistantMessageEvent {
  return event.type === 'message.assistant';
}

export function isToolCallEvent(event: SessionEvent): event is ToolCallEvent {
  return event.type === 'tool.call';
}

export function isToolResultEvent(event: SessionEvent): event is ToolResultEvent {
  return event.type === 'tool.result';
}

export function isMessageEvent(event: SessionEvent): event is UserMessageEvent | AssistantMessageEvent | SystemMessageEvent {
  return event.type === 'message.user' || event.type === 'message.assistant' || event.type === 'message.system';
}

export function isStreamingEvent(event: SessionEvent): boolean {
  return event.type.startsWith('stream.');
}

export function isErrorEvent(event: SessionEvent): event is ErrorAgentEvent | ErrorToolEvent | ErrorProviderEvent {
  return event.type.startsWith('error.');
}

export function isWorktreeEvent(event: SessionEvent): event is WorktreeAcquiredEvent | WorktreeCommitEvent | WorktreeReleasedEvent | WorktreeMergedEvent {
  return event.type.startsWith('worktree.');
}

export function isWorktreeAcquiredEvent(event: SessionEvent): event is WorktreeAcquiredEvent {
  return event.type === 'worktree.acquired';
}

export function isWorktreeCommitEvent(event: SessionEvent): event is WorktreeCommitEvent {
  return event.type === 'worktree.commit';
}

export function isWorktreeReleasedEvent(event: SessionEvent): event is WorktreeReleasedEvent {
  return event.type === 'worktree.released';
}

export function isWorktreeMergedEvent(event: SessionEvent): event is WorktreeMergedEvent {
  return event.type === 'worktree.merged';
}

export function isRulesLoadedEvent(event: SessionEvent): event is RulesLoadedEvent {
  return event.type === 'rules.loaded';
}

export function isContextClearedEvent(event: SessionEvent): event is ContextClearedEvent {
  return event.type === 'context.cleared';
}

export function isConfigReasoningLevelEvent(event: SessionEvent): event is ConfigReasoningLevelEvent {
  return event.type === 'config.reasoning_level';
}

export function isMessageDeletedEvent(event: SessionEvent): event is MessageDeletedEvent {
  return event.type === 'message.deleted';
}

export function isConfigEvent(event: SessionEvent): event is ConfigModelSwitchEvent | ConfigPromptUpdateEvent | ConfigReasoningLevelEvent {
  return event.type.startsWith('config.');
}

export function isSubagentSpawnedEvent(event: SessionEvent): event is SubagentSpawnedEvent {
  return event.type === 'subagent.spawned';
}

export function isSubagentStatusUpdateEvent(event: SessionEvent): event is SubagentStatusUpdateEvent {
  return event.type === 'subagent.status_update';
}

export function isSubagentCompletedEvent(event: SessionEvent): event is SubagentCompletedEvent {
  return event.type === 'subagent.completed';
}

export function isSubagentFailedEvent(event: SessionEvent): event is SubagentFailedEvent {
  return event.type === 'subagent.failed';
}

export function isSubagentEvent(event: SessionEvent): event is SubagentSpawnedEvent | SubagentStatusUpdateEvent | SubagentCompletedEvent | SubagentFailedEvent {
  return event.type.startsWith('subagent.');
}

export function isTodoWriteEvent(event: SessionEvent): event is TodoWriteEvent {
  return event.type === 'todo.write';
}

export function isTodoEvent(event: SessionEvent): event is TodoWriteEvent {
  return event.type.startsWith('todo.');
}

export function isTurnFailedEvent(event: SessionEvent): event is TurnFailedEvent {
  return event.type === 'turn.failed';
}

export function isTurnEvent(event: SessionEvent): event is TurnFailedEvent {
  return event.type.startsWith('turn.');
}

export function isHookTriggeredEvent(event: SessionEvent): event is HookTriggeredEvent {
  return event.type === 'hook.triggered';
}

export function isHookCompletedEvent(event: SessionEvent): event is HookCompletedEvent {
  return event.type === 'hook.completed';
}

export function isHookBackgroundStartedEvent(event: SessionEvent): event is HookBackgroundStartedEvent {
  return event.type === 'hook.background_started';
}

export function isHookBackgroundCompletedEvent(event: SessionEvent): event is HookBackgroundCompletedEvent {
  return event.type === 'hook.background_completed';
}

export function isHookEvent(event: SessionEvent): event is HookTriggeredEvent | HookCompletedEvent | HookBackgroundStartedEvent | HookBackgroundCompletedEvent {
  return event.type.startsWith('hook.');
}

export function isSkillAddedEvent(event: SessionEvent): event is SkillAddedEvent {
  return event.type === 'skill.added';
}

export function isSkillRemovedEvent(event: SessionEvent): event is SkillRemovedEvent {
  return event.type === 'skill.removed';
}

export function isSkillEvent(event: SessionEvent): event is SkillAddedEvent | SkillRemovedEvent {
  return event.type === 'skill.added' || event.type === 'skill.removed';
}

export function isMemoryLedgerEvent(event: SessionEvent): event is MemoryLedgerEvent {
  return event.type === 'memory.ledger';
}

export function isMemoryEvent(event: SessionEvent): event is MemoryLedgerEvent {
  return event.type.startsWith('memory.');
}
