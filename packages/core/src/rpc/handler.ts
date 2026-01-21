/**
 * @fileoverview RPC Handler
 *
 * Processes RPC requests and dispatches to appropriate handlers.
 * Supports middleware for cross-cutting concerns like auth and logging.
 *
 * All method handlers are now registered via the MethodRegistry system.
 * See handlers/ directory for individual handler implementations.
 */
import { EventEmitter } from 'events';
import { createLogger } from '../logging/logger.js';
import type {
  RpcRequest,
  RpcResponse,
  RpcEvent,
  RpcError,
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
  MemorySearchParams,
  MemoryAddEntryParams,
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

const logger = createLogger('rpc');

// =============================================================================
// Context Interface
// =============================================================================

/**
 * Context providing access to system components
 */
export interface RpcContext {
  sessionManager: SessionManager;
  agentManager: AgentManager;
  memoryStore: MemoryStore;
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
  /** Plan mode manager for plan mode operations (optional) */
  planManager?: PlanRpcManager;
  /** Todo manager for task tracking (optional) */
  todoManager?: TodoRpcManager;
  /** Device token manager for push notifications (optional) */
  deviceManager?: DeviceTokenRpcManager;
}

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
 * Plan mode manager interface for RPC operations
 */
export interface PlanRpcManager {
  /** Enter plan mode for a session */
  enterPlanMode(sessionId: string, skillName: string, blockedTools?: string[]): Promise<{ success: boolean; blockedTools: string[] }>;
  /** Exit plan mode for a session */
  exitPlanMode(sessionId: string, reason: 'approved' | 'cancelled', planPath?: string): Promise<{ success: boolean }>;
  /** Get plan mode state for a session */
  getPlanModeState(sessionId: string): { isActive: boolean; skillName?: string; blockedTools: string[] };
}

/**
 * Todo item for RPC responses
 */
export interface RpcTodoItem {
  id: string;
  content: string;
  activeForm: string;
  status: 'pending' | 'in_progress' | 'completed';
  source: 'agent' | 'user' | 'skill';
  createdAt: string;
  completedAt?: string;
  metadata?: Record<string, unknown>;
}

/**
 * Backlogged todo item for RPC responses
 */
export interface RpcBackloggedTask extends RpcTodoItem {
  /** When moved to backlog */
  backloggedAt: string;
  /** Why it was backlogged */
  backlogReason: 'session_clear' | 'context_compact' | 'session_end';
  /** Session it came from */
  sourceSessionId: string;
  /** Workspace for scoping */
  workspaceId: string;
  /** Session ID if restored */
  restoredToSessionId?: string;
  /** When restored */
  restoredAt?: string;
}

/**
 * Todo manager interface for RPC operations
 */
export interface TodoRpcManager {
  /** Get todos for a session */
  getTodos(sessionId: string): RpcTodoItem[];
  /** Get todo summary string for a session */
  getTodoSummary(sessionId: string): string;
  /** Get backlogged tasks for a workspace */
  getBacklog(workspaceId: string, options?: { includeRestored?: boolean; limit?: number }): RpcBackloggedTask[];
  /** Restore tasks from backlog to a session */
  restoreFromBacklog(sessionId: string, taskIds: string[]): Promise<RpcTodoItem[]>;
  /** Get count of unrestored backlogged tasks for a workspace */
  getBacklogCount(workspaceId: string): number;
}

// EventStore manager interface (implemented by EventStoreOrchestrator)
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
}

// Manager interfaces (implemented elsewhere)
interface SessionManager {
  createSession(params: SessionCreateParams): Promise<SessionCreateResult>;
  getSession(sessionId: string): Promise<SessionInfo | null>;
  resumeSession(sessionId: string): Promise<SessionInfo>;
  listSessions(params: SessionListParams): Promise<SessionInfo[]>;
  deleteSession(sessionId: string): Promise<boolean>;
  forkSession(sessionId: string, fromEventId?: string): Promise<SessionForkResult>;
  switchModel(sessionId: string, model: string): Promise<ModelSwitchResult>;
}

interface SessionInfo {
  sessionId: string;
  workingDirectory: string;
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
  messages: unknown[];
  lastUserPrompt?: string;
  lastAssistantResponse?: string;
}

interface AgentManager {
  prompt(params: AgentPromptParams): Promise<AgentPromptResult>;
  abort(sessionId: string): Promise<AgentAbortResult>;
  getState(sessionId: string): Promise<AgentGetStateResult>;
}

interface MemoryStore {
  searchEntries(params: MemorySearchParams): Promise<{ entries: unknown[]; totalCount: number }>;
  addEntry(params: MemoryAddEntryParams): Promise<{ id: string }>;
  listHandoffs(workingDirectory?: string, limit?: number): Promise<unknown[]>;
}

interface TranscriptionManager {
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

  /** Mark a token as invalid (e.g., after APNS 410 response) */
  markTokenInvalid(deviceToken: string): Promise<void>;
}

// =============================================================================
// Middleware Types
// =============================================================================

export type RpcMiddleware = (
  request: RpcRequest,
  next: (req: RpcRequest) => Promise<RpcResponse>
) => Promise<RpcResponse>;

// =============================================================================
// Handler Implementation
// =============================================================================

import { MethodRegistry } from './registry.js';
import { createSystemHandlers } from './handlers/system.handler.js';
import { createFilesystemHandlers } from './handlers/filesystem.handler.js';
import { createGitHandlers } from './handlers/git.handler.js';
import { createModelHandlers } from './handlers/model.handler.js';
import { createMemoryHandlers } from './handlers/memory.handler.js';
import { createTranscribeHandlers } from './handlers/transcribe.handler.js';
import { createSessionHandlers } from './handlers/session.handler.js';
import { createAgentHandlers } from './handlers/agent.handler.js';
import { createEventsHandlers } from './handlers/events.handler.js';
import { createTreeHandlers } from './handlers/tree.handler.js';
import { createSearchHandlers } from './handlers/search.handler.js';
import { createWorktreeHandlers } from './handlers/worktree.handler.js';
import { createContextHandlers } from './handlers/context.handler.js';
import { createMessageHandlers } from './handlers/message.handler.js';
import { createBrowserHandlers } from './handlers/browser.handler.js';
import { createSkillHandlers } from './handlers/skill.handler.js';
import { createFileHandlers } from './handlers/file.handler.js';
import { createToolHandlers } from './handlers/tool.handler.js';
import { createVoiceNotesHandlers } from './handlers/voiceNotes.handler.js';
import { createCanvasHandlers } from './handlers/canvas.handler.js';
import { createPlanHandlers } from './handlers/plan.handler.js';
import { createTodoHandlers } from './handlers/todo.handler.js';
import { getDeviceHandlers } from './handlers/device.handler.js';

export class RpcHandler extends EventEmitter {
  private context: RpcContext;
  private middleware: RpcMiddleware[] = [];
  private registry: MethodRegistry;

  constructor(context: RpcContext) {
    super();
    this.context = context;

    // Initialize method registry with extracted handlers
    this.registry = new MethodRegistry();
    this.registry.registerAll(createSystemHandlers());
    this.registry.registerAll(createFilesystemHandlers());
    this.registry.registerAll(createGitHandlers());
    this.registry.registerAll(createModelHandlers());
    this.registry.registerAll(createMemoryHandlers());
    this.registry.registerAll(createTranscribeHandlers());
    this.registry.registerAll(createSessionHandlers());
    this.registry.registerAll(createAgentHandlers());
    this.registry.registerAll(createEventsHandlers());
    this.registry.registerAll(createTreeHandlers());
    this.registry.registerAll(createSearchHandlers());
    this.registry.registerAll(createWorktreeHandlers());
    this.registry.registerAll(createContextHandlers());
    this.registry.registerAll(createMessageHandlers());
    this.registry.registerAll(createBrowserHandlers());
    this.registry.registerAll(createSkillHandlers());
    this.registry.registerAll(createFileHandlers());
    this.registry.registerAll(createToolHandlers());
    this.registry.registerAll(createVoiceNotesHandlers());
    this.registry.registerAll(createCanvasHandlers());
    this.registry.registerAll(createPlanHandlers());
    this.registry.registerAll(createTodoHandlers());
    this.registry.registerAll(getDeviceHandlers());

    logger.debug('RPC handler initialized', {
      registeredMethods: this.registry.list(),
    });
  }

  /**
   * Get the method registry (for testing or advanced usage)
   */
  getRegistry(): MethodRegistry {
    return this.registry;
  }

  /**
   * Register middleware
   */
  use(middleware: RpcMiddleware): void {
    this.middleware.push(middleware);
  }

  /**
   * Handle an RPC request
   */
  async handle(request: RpcRequest): Promise<RpcResponse> {
    logger.debug('Handling request', { method: request.method, id: request.id });

    try {
      // Build middleware chain
      const chain = this.buildMiddlewareChain();
      return await chain(request);
    } catch (error) {
      // Top-level error handling
      logger.error('Request handling error', error instanceof Error ? error : new Error(String(error)));
      return this.errorResponse(
        request.id,
        'INTERNAL_ERROR',
        error instanceof Error ? error.message : 'Unknown error'
      );
    }
  }

  /**
   * Emit an event to all listeners
   */
  emitEvent(event: RpcEvent): boolean {
    return super.emit('event', event);
  }

  /**
   * Add event listener
   */
  on(event: 'event', listener: (event: RpcEvent) => void): this {
    return super.on(event, listener);
  }

  /**
   * Remove event listener
   */
  off(event: 'event', listener: (event: RpcEvent) => void): this {
    return super.off(event, listener);
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private buildMiddlewareChain(): (req: RpcRequest) => Promise<RpcResponse> {
    // Start with the actual handler
    let chain = (req: RpcRequest) => this.dispatch(req);

    // Wrap with middleware in reverse order
    for (let i = this.middleware.length - 1; i >= 0; i--) {
      const middleware = this.middleware[i];
      if (!middleware) continue;
      const next = chain;
      chain = (req) => middleware(req, next);
    }

    return chain;
  }

  private async dispatch(request: RpcRequest): Promise<RpcResponse> {
    try {
      // All methods are now handled by the registry
      return this.registry.dispatch(request, this.context);
    } catch (error) {
      logger.error('Handler error', error instanceof Error ? error : new Error(String(error)));
      return this.errorResponse(
        request.id,
        'INTERNAL_ERROR',
        error instanceof Error ? error.message : 'Unknown error'
      );
    }
  }

  // ===========================================================================
  // Response Helpers
  // ===========================================================================

  private errorResponse(id: string, code: string, message: string, details?: unknown): RpcResponse {
    const error: RpcError = { code, message };
    if (details !== undefined) {
      error.details = details;
    }
    return {
      id,
      success: false,
      error,
    };
  }
}
