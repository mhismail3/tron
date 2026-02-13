/**
 * @fileoverview RPC Context Type Definitions
 *
 * Extracted from handler.ts to break circular dependencies.
 * Handlers import these types instead of importing from handler.ts.
 */

import type {
  ContextGetSnapshotResult,
  ContextGetDetailedSnapshotResult,
  ContextPreviewCompactionResult,
  ContextConfirmCompactionResult,
  ContextCanAcceptTurnResult,
  ContextClearResult,
  SessionCreateParams,
  SessionCreateResult,
  SessionListParams,
  SessionForkResult,
  ModelSwitchResult,
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortResult,
  AgentGetStateResult,
  TranscribeAudioParams,
  TranscribeAudioResult,
  TranscribeListModelsResult,
  BrowserStartStreamParams,
  BrowserStartStreamResult,
  BrowserStopStreamParams,
  BrowserStopStreamResult,
  BrowserGetStatusParams,
  BrowserGetStatusResult,
  SkillListParams,
  SkillListResult,
  SkillGetParams,
  SkillGetResult,
  SkillRefreshParams,
  SkillRefreshResult,
  SkillRemoveParams,
  SkillRemoveResult,
} from './types.js';

// =============================================================================
// Context Interface
// =============================================================================

/**
 * Context providing access to system components
 */
export interface RpcContext {
  sessionManager: SessionManager;
  agentManager: AgentManager;
  /** EventStore for event-sourced session operations (optional for backwards compatibility) */
  eventStore?: EventStoreManager;
  /** Worktree manager for git worktree operations (optional) */
  worktreeManager?: WorktreeRpcManager;
  /** Transcription manager (optional) */
  transcriptionManager?: TranscriptionManager;
  /** Context manager for compaction operations (optional) */
  contextManager?: ContextRpcManager;
  /** Browser manager for browser automation (optional) */
  browserManager?: BrowserRpcManager;
  /** Skill manager for skill operations (optional) */
  skillManager?: SkillRpcManager;
  /** Tool call tracker for interactive tools (optional) */
  toolCallTracker?: ToolCallTrackerManager;
  /** Canvas manager for UI artifact persistence (optional) */
  canvasManager?: CanvasRpcManager;
  /** Task manager for persistent task management (optional) */
  taskManager?: TaskRpcManager;
  /** Device token manager for push notifications (optional) */
  deviceManager?: DeviceTokenRpcManager;
  /** Sandbox manager for container operations (optional) */
  sandboxManager?: SandboxRpcManager;
}

// =============================================================================
// Manager Interfaces
// =============================================================================

/**
 * Tool call tracker interface for managing pending interactive tool calls
 */
export interface ToolCallTrackerManager {
  resolve(toolCallId: string, result: unknown): boolean;
  hasPending(toolCallId: string): boolean;
}

/**
 * Worktree manager interface for RPC operations
 */
export interface WorktreeRpcManager {
  getWorktreeStatus(sessionId: string): Promise<{
    isolated: boolean;
    branch: string;
    baseCommit: string;
    path: string;
    hasUncommittedChanges?: boolean;
    commitCount?: number;
  } | null>;
  commitWorktree(sessionId: string, message: string): Promise<{
    success: boolean;
    commitHash?: string;
    filesChanged?: string[];
    error?: string;
  }>;
  mergeWorktree(sessionId: string, targetBranch: string, strategy?: 'merge' | 'rebase' | 'squash'): Promise<{
    success: boolean;
    mergeCommit?: string;
    conflicts?: string[];
  }>;
  listWorktrees(): Promise<Array<{ path: string; branch: string; sessionId?: string }>>;
}

/**
 * Context manager interface for RPC operations
 */
export interface ContextRpcManager {
  getContextSnapshot(sessionId: string): ContextGetSnapshotResult;
  getDetailedContextSnapshot(sessionId: string): ContextGetDetailedSnapshotResult;
  shouldCompact(sessionId: string): boolean;
  previewCompaction(sessionId: string): Promise<ContextPreviewCompactionResult>;
  confirmCompaction(sessionId: string, opts?: { editedSummary?: string }): Promise<ContextConfirmCompactionResult>;
  canAcceptTurn(sessionId: string, opts: { estimatedResponseTokens: number }): ContextCanAcceptTurnResult;
  clearContext(sessionId: string): Promise<ContextClearResult>;
}

/**
 * Task manager interface for RPC operations
 */
export interface TaskRpcManager {
  /** List tasks with optional filters */
  listTasks(filter?: Record<string, unknown>): unknown;
  /** Get a task by ID */
  getTask(taskId: string): unknown;
  /** Create a task */
  createTask(params: Record<string, unknown>): unknown;
  /** Update a task */
  updateTask(taskId: string, params: Record<string, unknown>): unknown;
  /** Delete a task */
  deleteTask(taskId: string): unknown;
  /** Search tasks */
  searchTasks(query: string, limit?: number): unknown;
  /** Get task activity */
  getActivity(taskId: string, limit?: number): unknown;
  /** List projects */
  listProjects(filter?: Record<string, unknown>): unknown;
  /** Get a project */
  getProject(projectId: string): unknown;
  /** Get project with full details (tasks, area) */
  getProjectWithDetails(projectId: string): unknown;
  /** Create a project */
  createProject(params: Record<string, unknown>): unknown;
  /** Update a project */
  updateProject(projectId: string, params: Record<string, unknown>): unknown;
  /** Delete a project */
  deleteProject(projectId: string): unknown;
  /** List areas */
  listAreas(filter?: Record<string, unknown>): unknown;
  /** Get an area */
  getArea(areaId: string): unknown;
  /** Create an area */
  createArea(params: Record<string, unknown>): unknown;
  /** Update an area */
  updateArea(areaId: string, params: Record<string, unknown>): unknown;
  /** Delete an area */
  deleteArea(areaId: string): unknown;
}

/**
 * EventStore manager interface (implemented by EventStoreOrchestrator)
 */
export interface EventStoreManager {
  // Event operations
  getEventHistory(sessionId: string, options?: { types?: string[]; limit?: number; beforeEventId?: string }): Promise<{ events: unknown[]; hasMore: boolean; oldestEventId?: string }>;
  getEventsSince(options: { sessionId?: string; workspaceId?: string; afterEventId?: string; afterTimestamp?: string; limit?: number }): Promise<{ events: unknown[]; nextCursor?: string; hasMore: boolean }>;
  appendEvent(sessionId: string, type: string, payload: Record<string, unknown>, parentId?: string): Promise<{ event: unknown; newHeadEventId: string }>;

  // Tree operations
  getTreeVisualization(sessionId: string, options?: { maxDepth?: number; messagesOnly?: boolean }): Promise<{ sessionId: string; rootEventId: string; headEventId: string; nodes: unknown[]; totalEvents: number }>;
  getBranches(sessionId: string): Promise<{ mainBranch: unknown; forks: unknown[] }>;
  getSubtree(eventId: string, options?: { maxDepth?: number; direction?: 'descendants' | 'ancestors' }): Promise<{ nodes: unknown[] }>;
  getAncestors(eventId: string): Promise<{ events: unknown[] }>;

  // Search
  searchContent(query: string, options?: { sessionId?: string; workspaceId?: string; types?: string[]; limit?: number }): Promise<{ results: unknown[]; totalCount: number }>;

  // Message operations
  deleteMessage(sessionId: string, targetEventId: string, reason?: 'user_request' | 'content_policy' | 'context_management'): Promise<{ id: string; payload: unknown }>;

  // Memory operations
  getLedgerEntries(workingDirectory: string, options?: { limit?: number; offset?: number; tags?: string[] }): Promise<{ entries: unknown[]; hasMore: boolean; totalCount: number }>;
}

/**
 * Session manager interface
 */
export interface SessionManager {
  createSession(params: SessionCreateParams): Promise<SessionCreateResult>;
  getSession(sessionId: string): Promise<SessionInfo | null>;
  resumeSession(sessionId: string): Promise<SessionInfo>;
  listSessions(params: SessionListParams): Promise<SessionInfo[]>;
  deleteSession(sessionId: string): Promise<boolean>;
  forkSession(sessionId: string, fromEventId?: string): Promise<SessionForkResult>;
  switchModel(sessionId: string, model: string): Promise<ModelSwitchResult>;
}

export interface SessionInfo {
  sessionId: string;
  workingDirectory: string;
  title?: string;
  model: string;
  messageCount: number;
  inputTokens: number;
  outputTokens: number;
  lastTurnInputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  cost: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  parentSessionId?: string;
  messages: unknown[];
  lastUserPrompt?: string;
  lastAssistantResponse?: string;
}

/**
 * Agent manager interface
 */
export interface AgentManager {
  prompt(params: AgentPromptParams): Promise<AgentPromptResult>;
  abort(sessionId: string): Promise<AgentAbortResult>;
  getState(sessionId: string): Promise<AgentGetStateResult>;
  triggerLedgerUpdate(sessionId: string): Promise<{ written: boolean; title?: string; entryType?: string; reason?: string }>;
}

/**
 * Transcription manager interface
 */
export interface TranscriptionManager {
  transcribeAudio(params: TranscribeAudioParams): Promise<TranscribeAudioResult>;
  listModels(): Promise<TranscribeListModelsResult>;
}

/**
 * Browser manager interface for RPC operations
 */
export interface BrowserRpcManager {
  startStream(params: BrowserStartStreamParams): Promise<BrowserStartStreamResult>;
  stopStream(params: BrowserStopStreamParams): Promise<BrowserStopStreamResult>;
  getStatus(params: BrowserGetStatusParams): Promise<BrowserGetStatusResult>;
}

/**
 * Skill manager interface for RPC operations
 */
export interface SkillRpcManager {
  listSkills(params: SkillListParams): Promise<SkillListResult>;
  getSkill(params: SkillGetParams): Promise<SkillGetResult>;
  refreshSkills(params: SkillRefreshParams): Promise<SkillRefreshResult>;
  removeSkill(params: SkillRemoveParams): Promise<SkillRemoveResult>;
}

/**
 * Canvas manager interface for RPC operations
 */
export interface CanvasRpcManager {
  getCanvas(canvasId: string): Promise<{
    found: boolean;
    canvas?: {
      canvasId: string;
      sessionId: string;
      title?: string;
      ui: Record<string, unknown>;
      state?: Record<string, unknown>;
      savedAt: string;
    };
  }>;
}

/**
 * Device token info stored in database
 */
export interface RpcDeviceToken {
  id: string;
  deviceToken: string;
  sessionId?: string;
  workspaceId?: string;
  platform: 'ios';
  environment: 'sandbox' | 'production';
  createdAt: string;
  lastUsedAt: string;
  isActive: boolean;
}

/**
 * Device token manager interface for RPC operations (push notifications)
 */
export interface DeviceTokenRpcManager {
  /** Register or update a device token */
  registerToken(params: {
    deviceToken: string;
    sessionId?: string;
    workspaceId?: string;
    environment?: 'sandbox' | 'production';
  }): Promise<{ id: string; created: boolean }>;

  /** Unregister (deactivate) a device token */
  unregisterToken(deviceToken: string): Promise<{ success: boolean }>;

  /** Get active tokens for a session */
  getTokensForSession(sessionId: string): Promise<RpcDeviceToken[]>;

  /** Get active tokens for a workspace */
  getTokensForWorkspace(workspaceId: string): Promise<RpcDeviceToken[]>;

  /** Get all active device tokens (for global notifications) */
  getAllActiveTokens(): Promise<RpcDeviceToken[]>;

  /** Mark a token as invalid (e.g., after APNS 410 response) */
  markTokenInvalid(deviceToken: string): Promise<void>;
}

/**
 * Sandbox manager interface for RPC operations
 */
export interface SandboxRpcManager {
  listContainers(): Promise<{
    containers: Array<{
      name: string;
      image: string;
      status: string;
      ports: string[];
      purpose?: string;
      createdAt: string;
      createdBySession: string;
      workingDirectory: string;
    }>;
    tailscaleIp?: string;
  }>;
  stopContainer(name: string): Promise<{ success: boolean }>;
  startContainer(name: string): Promise<{ success: boolean }>;
  killContainer(name: string): Promise<{ success: boolean }>;
}

// =============================================================================
// Middleware Types
// =============================================================================

import type { RpcRequest, RpcResponse } from './types.js';

export type RpcMiddleware = (
  request: RpcRequest,
  next: (req: RpcRequest) => Promise<RpcResponse>
) => Promise<RpcResponse>;
