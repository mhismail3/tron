/**
 * @fileoverview RPC Handlers Module
 *
 * Exports handler utilities and handler implementations.
 * Individual handler modules will be added as they are extracted.
 */

// Base utilities
export {
  extractParams,
  extractRequiredParams,
  requireManager,
  withErrorHandling,
  createHandler,
  ErrorCodes,
  notFoundError,
  type TypedHandler,
  type ParamsOf,
  type CreateHandlerOptions,
} from './base.js';

// Handler implementations
export {
  handleSystemPing,
  handleSystemGetInfo,
  createSystemHandlers,
} from './system.handler.js';

export {
  handleFilesystemListDir,
  handleFilesystemGetHome,
  handleFilesystemCreateDir,
  createFilesystemHandlers,
} from './filesystem.handler.js';

export {
  handleModelSwitch,
  handleModelList,
  createModelHandlers,
} from './model.handler.js';

export {
  handleMemorySearch,
  handleMemoryAddEntry,
  handleMemoryGetHandoffs,
  createMemoryHandlers,
} from './memory.handler.js';

export {
  handleTranscribeAudio,
  handleTranscribeListModels,
  createTranscribeHandlers,
} from './transcribe.handler.js';

export {
  handleSessionCreate,
  handleSessionResume,
  handleSessionList,
  handleSessionDelete,
  handleSessionFork,
  createSessionHandlers,
} from './session.handler.js';

export {
  handleAgentPrompt,
  handleAgentAbort,
  handleAgentGetState,
  createAgentHandlers,
} from './agent.handler.js';

export {
  handleEventsGetHistory,
  handleEventsGetSince,
  handleEventsAppend,
  createEventsHandlers,
} from './events.handler.js';

export {
  handleTreeGetVisualization,
  handleTreeGetBranches,
  handleTreeGetSubtree,
  handleTreeGetAncestors,
  createTreeHandlers,
} from './tree.handler.js';

export {
  handleSearchContent,
  handleSearchEvents,
  createSearchHandlers,
} from './search.handler.js';

export {
  handleWorktreeGetStatus,
  handleWorktreeCommit,
  handleWorktreeMerge,
  handleWorktreeList,
  createWorktreeHandlers,
} from './worktree.handler.js';

export {
  handleContextGetSnapshot,
  handleContextGetDetailedSnapshot,
  handleContextShouldCompact,
  handleContextPreviewCompaction,
  handleContextConfirmCompaction,
  handleContextCanAcceptTurn,
  handleContextClear,
  createContextHandlers,
} from './context.handler.js';

export {
  handleMessageDelete,
  createMessageHandlers,
} from './message.handler.js';

export {
  handleBrowserStartStream,
  handleBrowserStopStream,
  handleBrowserGetStatus,
  createBrowserHandlers,
} from './browser.handler.js';

export {
  handleSkillList,
  handleSkillGet,
  handleSkillRefresh,
  handleSkillRemove,
  createSkillHandlers,
} from './skill.handler.js';

export {
  handleFileRead,
  createFileHandlers,
} from './file.handler.js';

export {
  handleToolResult,
  createToolHandlers,
} from './tool.handler.js';

export {
  handleVoiceNotesSave,
  handleVoiceNotesList,
  handleVoiceNotesDelete,
  createVoiceNotesHandlers,
} from './voiceNotes.handler.js';
