/**
 * @fileoverview Browser-safe exports for @tron/core
 *
 * This entry point only exports code that can run in browsers:
 * - Types and interfaces
 * - RPC protocol types
 * - Model catalog (no Node.js dependencies)
 * - Provider types (no SDK dependencies)
 */

// Re-export types (only browser-safe ones)
export type {
  // Messages
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  TextContent,
  ImageContent,
  ThinkingContent,
  ToolCall,
  TokenUsage,
  Context,
  Tool,
  // Events
  StreamEvent,
  TronEvent,
  TronEventType,
} from './types/index.js';

// Re-export RPC types (protocol only, no handler)
export type {
  RpcRequest,
  RpcResponse,
  RpcEvent,
  RpcError,
  RpcMethod,
  RpcEventType,
  // Session types
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
  SessionRewindParams,
  SessionRewindResult,
  // Agent types
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  AgentGetStateResult,
  // Model types
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListParams,
  ModelListResult,
  // System types
  SystemPingParams,
  SystemPingResult,
  SystemGetInfoParams,
  SystemGetInfoResult,
  // Filesystem types
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeParams,
  FilesystemGetHomeResult,
  // Memory types
  MemorySearchParams,
  RpcMemorySearchResult,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  // Event data types
  AgentTextDeltaEvent,
  AgentThinkingDeltaEvent,
  AgentToolStartEvent,
  AgentToolEndEvent,
  AgentCompleteEvent,
  // Worktree types
  WorktreeInfoRpc,
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListParams,
  WorktreeListResult,
} from './rpc/types.js';

// Re-export model catalog (browser-safe)
export {
  ANTHROPIC_MODELS,
  ANTHROPIC_MODEL_CATEGORIES,
  getModelById,
  getRecommendedModel,
  getTierIcon,
  getTierLabel,
  formatContextWindow,
  formatModelPricing,
  getAllModels,
  isValidModelId,
  type ModelInfo,
  type ModelCategory,
} from './providers/models.js';

// Re-export feature flags types
export type { FeatureFlags } from './features/index.js';
