/**
 * @fileoverview RPC Types Index
 *
 * Re-exports all RPC types from domain-specific files.
 * This file provides backward compatibility for imports from './types'.
 */

// Re-export branded types from events
export type { EventId, SessionId, WorkspaceId, BranchId } from '@infrastructure/events/types.js';

// Base types
export type {
  RpcRequest,
  RpcResponse,
  RpcError,
  RpcEvent,
  RpcMethod,
} from './base.js';

// Session types
export type {
  SessionCreateParams,
  SessionCreateResult,
  SessionResumeParams,
  SessionResumeResult,
  SessionListParams,
  SessionListResult,
  SessionDeleteParams,
  SessionDeleteResult,
  SessionForkParams,
  SessionForkResult,
  SessionGetHeadParams,
  SessionGetHeadResult,
  SessionGetStateParams,
  SessionGetStateResult,
} from './session.js';

// Agent types
export type {
  FileAttachment,
  PromptSkillReference,
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  CurrentTurnToolCall,
  AgentGetStateResult,
} from './agent.js';

// Model types
export type {
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListParams,
  ModelListResult,
} from './model.js';

// Memory types
export type {
  MemorySearchParams,
  RpcMemorySearchResult,
  MemorySearchResultRpc,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
} from './memory.js';

// Skill types
export type {
  RpcSkillInfo,
  RpcSkillMetadata,
  SkillListParams,
  SkillListResult,
  SkillGetParams,
  SkillGetResult,
  SkillRefreshParams,
  SkillRefreshResult,
  SkillRemoveParams,
  SkillRemoveResult,
} from './skill.js';

// Event types
export type {
  EventsGetHistoryParams,
  EventsGetHistoryResult,
  EventsGetSinceParams,
  EventsGetSinceResult,
  EventsSubscribeParams,
  EventsSubscribeResult,
  EventsUnsubscribeParams,
  EventsUnsubscribeResult,
  EventsAppendParams,
  EventsAppendResult,
} from './events.js';

// Tree types
export type {
  TreeNodeCompact,
  TreeGetVisualizationParams,
  TreeGetVisualizationResult,
  TreeGetBranchesParams,
  TreeBranchInfo,
  TreeGetBranchesResult,
  TreeGetSubtreeParams,
  TreeGetSubtreeResult,
  TreeGetAncestorsParams,
  TreeGetAncestorsResult,
  TreeCompareBranchesParams,
  TreeCompareBranchesResult,
} from './tree.js';

// Search types
export type {
  SearchContentParams,
  SearchContentResult,
  SearchEventsParams,
  SearchEventsResult,
} from './search.js';

// System types
export type {
  SystemPingParams,
  SystemPingResult,
  SystemGetInfoParams,
  SystemGetInfoResult,
  SystemShutdownParams,
  SystemShutdownResult,
} from './system.js';

// Transcription types
export type {
  TranscribeAudioParams,
  TranscribeAudioResult,
  TranscriptionModelInfo,
  TranscribeListModelsParams,
  TranscribeListModelsResult,
} from './transcription.js';

// Filesystem types
export type {
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeParams,
  FilesystemGetHomeResult,
  FilesystemCreateDirParams,
  FilesystemCreateDirResult,
  FileReadParams,
  FileReadResult,
} from './filesystem.js';

// Git types
export type {
  GitCloneParams,
  GitCloneResult,
} from './git.js';

// Streaming types
export type {
  RpcEventType,
  NormalizedTokenUsage,
  AgentTurnEndEvent,
  AgentTextDeltaEvent,
  AgentThinkingDeltaEvent,
  AgentToolStartEvent,
  AgentToolEndEvent,
  AgentCompleteEvent,
  RpcSubagentSpawnedData,
  RpcSubagentStatusData,
  RpcSubagentCompletedData,
  RpcSubagentFailedData,
  SessionForkedEvent,
  EventsNewEvent,
  EventsBatchEvent,
  TreeUpdatedEvent,
  TreeBranchCreatedEvent,
} from './streaming.js';

// UI Canvas types
export type {
  UIRenderStartEvent,
  UIRenderChunkEvent,
  UIRenderCompleteEvent,
  UIActionEvent,
  UIStateChangeEvent,
} from './ui-canvas.js';

// Worktree types
export type {
  WorktreeInfoRpc,
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListParams,
  WorktreeListResult,
} from './worktree.js';

// Context types
export type {
  ContextGetSnapshotParams,
  ContextGetSnapshotResult,
  ContextGetDetailedSnapshotParams,
  ContextDetailedMessageInfo,
  RpcAddedSkillInfo,
  RpcRulesFileInfo,
  RpcRulesInfo,
  ContextGetDetailedSnapshotResult,
  ContextShouldCompactParams,
  ContextShouldCompactResult,
  ContextPreviewCompactionParams,
  ContextPreviewCompactionResult,
  ContextConfirmCompactionParams,
  ContextConfirmCompactionResult,
  ContextCanAcceptTurnParams,
  ContextCanAcceptTurnResult,
  ContextClearParams,
  ContextClearResult,
  ContextCompactParams,
  ContextCompactResult,
} from './context.js';

// Voice notes types
export type {
  VoiceNotesSaveParams,
  VoiceNotesSaveResult,
  VoiceNotesListParams,
  VoiceNoteMetadata,
  VoiceNotesListResult,
  VoiceNotesDeleteParams,
  VoiceNotesDeleteResult,
} from './voice-notes.js';

// Message types
export type {
  MessageDeleteParams,
  MessageDeleteResult,
} from './message.js';

// Browser types
export type {
  BrowserStartStreamParams,
  BrowserStartStreamResult,
  BrowserStopStreamParams,
  BrowserStopStreamResult,
  BrowserGetStatusParams,
  BrowserGetStatusResult,
  BrowserFrameEvent,
} from './browser.js';

// Tool result types
export type {
  ToolResultParams,
  ToolResultResult,
} from './tool-result.js';

// Canvas types
export type {
  CanvasGetParams,
  CanvasArtifactData,
  CanvasGetResult,
} from './canvas.js';

// Todo types
export type {
  TodoListParams,
  TodoListResult,
  RpcTodoItemResult,
  TodoGetBacklogParams,
  TodoGetBacklogResult,
  RpcBackloggedTaskResult,
  TodoRestoreParams,
  TodoRestoreResult,
  TodoGetBacklogCountParams,
  TodoGetBacklogCountResult,
} from './todo.js';

// =============================================================================
// Type Guards
// =============================================================================

import type { RpcRequest, RpcResponse, RpcEvent } from './base.js';

export function isRpcRequest(msg: unknown): msg is RpcRequest {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'method' in msg &&
    typeof (msg as RpcRequest).id === 'string' &&
    typeof (msg as RpcRequest).method === 'string'
  );
}

export function isRpcResponse(msg: unknown): msg is RpcResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'success' in msg &&
    typeof (msg as RpcResponse).id === 'string' &&
    typeof (msg as RpcResponse).success === 'boolean'
  );
}

export function isRpcEvent(msg: unknown): msg is RpcEvent {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'type' in msg &&
    'timestamp' in msg &&
    'data' in msg &&
    typeof (msg as RpcEvent).type === 'string'
  );
}
