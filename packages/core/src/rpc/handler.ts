/**
 * @fileoverview RPC Handler
 *
 * Processes RPC requests and dispatches to appropriate handlers.
 * Supports middleware for cross-cutting concerns like auth and logging.
 */
import { EventEmitter } from 'events';
import { createLogger } from '../logging/logger.js';
import { VERSION } from '../index.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type {
  RpcRequest,
  RpcResponse,
  RpcEvent,
  RpcError,
  RpcMethod,
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
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  AgentGetStateResult,
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListResult,
  MemorySearchParams,
  RpcMemorySearchResult,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
  SystemPingResult,
  SystemGetInfoResult,
  FilesystemListDirParams,
  FilesystemListDirResult,
  FilesystemGetHomeResult,
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListResult,
} from './types.js';
import { ANTHROPIC_MODELS } from '../providers/models.js';

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
}

// Manager interfaces (implemented elsewhere)
interface SessionManager {
  createSession(params: SessionCreateParams): Promise<SessionCreateResult>;
  getSession(sessionId: string): Promise<SessionInfo | null>;
  resumeSession(sessionId: string): Promise<SessionInfo>;
  listSessions(params: SessionListParams): Promise<SessionInfo[]>;
  deleteSession(sessionId: string): Promise<boolean>;
  // Updated to use EventId-based operations (EventStore integration)
  forkSession(sessionId: string, fromEventId?: string): Promise<SessionForkResult>;
  rewindSession(sessionId: string, toEventId: string): Promise<SessionRewindResult>;
  switchModel(sessionId: string, model: string): Promise<ModelSwitchResult>;
}

interface SessionInfo {
  sessionId: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  messages: unknown[];
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

export class RpcHandler extends EventEmitter {
  private context: RpcContext;
  private middleware: RpcMiddleware[] = [];
  private startTime: number;

  constructor(context: RpcContext) {
    super();
    this.context = context;
    this.startTime = Date.now();
    logger.debug('RPC handler initialized');
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
      switch (request.method as RpcMethod) {
        // Session methods
        case 'session.create':
          return this.handleSessionCreate(request);
        case 'session.resume':
          return this.handleSessionResume(request);
        case 'session.list':
          return this.handleSessionList(request);
        case 'session.delete':
          return this.handleSessionDelete(request);
        case 'session.fork':
          return this.handleSessionFork(request);
        case 'session.rewind':
          return this.handleSessionRewind(request);

        // Agent methods
        case 'agent.prompt':
          return this.handleAgentPrompt(request);
        case 'agent.abort':
          return this.handleAgentAbort(request);
        case 'agent.getState':
          return this.handleAgentGetState(request);

        // Model methods
        case 'model.switch':
          return this.handleModelSwitch(request);
        case 'model.list':
          return this.handleModelList(request);

        // Memory methods
        case 'memory.search':
          return this.handleMemorySearch(request);
        case 'memory.addEntry':
          return this.handleMemoryAddEntry(request);
        case 'memory.getHandoffs':
          return this.handleMemoryGetHandoffs(request);

        // Filesystem methods
        case 'filesystem.listDir':
          return this.handleFilesystemListDir(request);
        case 'filesystem.getHome':
          return this.handleFilesystemGetHome(request);

        // System methods
        case 'system.ping':
          return this.handleSystemPing(request);
        case 'system.getInfo':
          return this.handleSystemGetInfo(request);

        // Event methods (requires eventStore in context)
        case 'events.getHistory':
          return this.handleEventsGetHistory(request);
        case 'events.getSince':
          return this.handleEventsGetSince(request);
        case 'events.append':
          return this.handleEventsAppend(request);

        // Tree methods (requires eventStore in context)
        case 'tree.getVisualization':
          return this.handleTreeGetVisualization(request);
        case 'tree.getBranches':
          return this.handleTreeGetBranches(request);
        case 'tree.getSubtree':
          return this.handleTreeGetSubtree(request);
        case 'tree.getAncestors':
          return this.handleTreeGetAncestors(request);

        // Search methods
        case 'search.content':
          return this.handleSearchContent(request);
        case 'search.events':
          return this.handleSearchEvents(request);

        // Worktree methods
        case 'worktree.getStatus':
          return this.handleWorktreeGetStatus(request);
        case 'worktree.commit':
          return this.handleWorktreeCommit(request);
        case 'worktree.merge':
          return this.handleWorktreeMerge(request);
        case 'worktree.list':
          return this.handleWorktreeList(request);

        default:
          return this.errorResponse(request.id, 'METHOD_NOT_FOUND', `Unknown method: ${request.method}`);
      }
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
  // Session Handlers
  // ===========================================================================

  private async handleSessionCreate(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as SessionCreateParams | undefined;

    if (!params?.workingDirectory) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'workingDirectory is required');
    }

    const result = await this.context.sessionManager.createSession(params);
    return this.successResponse(request.id, result);
  }

  private async handleSessionResume(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as SessionResumeParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    try {
      // Resume the session (activates it for agent operations)
      const session = await this.context.sessionManager.resumeSession(params.sessionId);

      const result: SessionResumeResult = {
        sessionId: session.sessionId,
        model: session.model,
        messageCount: session.messages.length,
        lastActivity: session.lastActivity,
      };

      return this.successResponse(request.id, result);
    } catch (error) {
      if (error instanceof Error && error.message.includes('not found')) {
        return this.errorResponse(request.id, 'SESSION_NOT_FOUND', 'Session does not exist');
      }
      throw error;
    }
  }

  private async handleSessionList(request: RpcRequest): Promise<RpcResponse> {
    const params = (request.params || {}) as SessionListParams;
    const sessions = await this.context.sessionManager.listSessions(params);

    const result: SessionListResult = {
      sessions: sessions.map((s) => ({
        sessionId: s.sessionId,
        workingDirectory: s.workingDirectory,
        model: s.model,
        messageCount: s.messageCount,
        createdAt: s.createdAt,
        lastActivity: s.lastActivity,
        isActive: s.isActive,
      })),
    };

    return this.successResponse(request.id, result);
  }

  private async handleSessionDelete(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as SessionDeleteParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const deleted = await this.context.sessionManager.deleteSession(params.sessionId);

    const result: SessionDeleteResult = { deleted };
    return this.successResponse(request.id, result);
  }

  private async handleSessionFork(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as SessionForkParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    // Fork now uses EventStore via EventId
    // The sessionManager will be updated to use EventStore internally
    const result = await this.context.sessionManager.forkSession(
      params.sessionId,
      params.fromEventId // Pass eventId, sessionManager handles conversion
    );

    return this.successResponse(request.id, result);
  }

  private async handleSessionRewind(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as SessionRewindParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params.toEventId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'toEventId is required');
    }

    // Rewind now uses EventStore via EventId
    const result = await this.context.sessionManager.rewindSession(
      params.sessionId,
      params.toEventId // Pass eventId, sessionManager handles conversion
    );

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Agent Handlers
  // ===========================================================================

  private async handleAgentPrompt(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as AgentPromptParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params?.prompt) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'prompt is required');
    }

    const result = await this.context.agentManager.prompt(params);
    return this.successResponse(request.id, result);
  }

  private async handleAgentAbort(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as AgentAbortParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const result = await this.context.agentManager.abort(params.sessionId);
    return this.successResponse(request.id, result);
  }

  private async handleAgentGetState(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as AgentGetStateParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const result = await this.context.agentManager.getState(params.sessionId);
    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Model Handlers
  // ===========================================================================

  private async handleModelSwitch(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as ModelSwitchParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params?.model) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'model is required');
    }

    // Validate model exists
    const modelInfo = ANTHROPIC_MODELS.find((m) => m.id === params.model);
    if (!modelInfo) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', `Unknown model: ${params.model}`);
    }

    const result = await this.context.sessionManager.switchModel(params.sessionId, params.model);
    return this.successResponse(request.id, result);
  }

  private async handleModelList(request: RpcRequest): Promise<RpcResponse> {
    const result: ModelListResult = {
      models: ANTHROPIC_MODELS.map((m) => ({
        id: m.id,
        name: m.shortName,
        provider: 'anthropic',
        contextWindow: m.contextWindow,
        supportsThinking: m.supportsThinking,
        supportsImages: true, // All Claude models support images
      })),
    };

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Memory Handlers
  // ===========================================================================

  private async handleMemorySearch(request: RpcRequest): Promise<RpcResponse> {
    const params = (request.params || {}) as MemorySearchParams;

    const searchResult = await this.context.memoryStore.searchEntries(params);

    const result: RpcMemorySearchResult = {
      entries: searchResult.entries.map((e: unknown) => {
        const entry = e as Record<string, unknown>;
        return {
          id: entry.id as string,
          type: entry.type as string,
          content: entry.content as string,
          source: entry.source as string,
          relevance: (entry.relevance as number) ?? 1.0,
          timestamp: entry.timestamp as string,
        };
      }),
      totalCount: searchResult.totalCount,
    };

    return this.successResponse(request.id, result);
  }

  private async handleMemoryAddEntry(request: RpcRequest): Promise<RpcResponse> {
    const params = request.params as MemoryAddEntryParams | undefined;

    if (!params?.type) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'type is required');
    }
    if (!params?.content) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'content is required');
    }

    const addResult = await this.context.memoryStore.addEntry(params);

    const result: MemoryAddEntryResult = {
      id: addResult.id,
      created: true,
    };

    return this.successResponse(request.id, result);
  }

  private async handleMemoryGetHandoffs(request: RpcRequest): Promise<RpcResponse> {
    const params = (request.params || {}) as MemoryGetHandoffsParams;

    const handoffs = await this.context.memoryStore.listHandoffs(
      params.workingDirectory,
      params.limit
    );

    const result: MemoryGetHandoffsResult = {
      handoffs: handoffs.map((h: unknown) => {
        const handoff = h as Record<string, unknown>;
        return {
          id: handoff.id as string,
          sessionId: handoff.sessionId as string,
          summary: handoff.summary as string,
          createdAt: handoff.createdAt as string,
        };
      }),
    };

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Filesystem Handlers
  // ===========================================================================

  private async handleFilesystemListDir(request: RpcRequest): Promise<RpcResponse> {
    const params = (request.params || {}) as FilesystemListDirParams;

    // Default to home directory if no path specified
    const targetPath = params.path || os.homedir();
    const showHidden = params.showHidden ?? false;

    try {
      // Resolve to absolute path and normalize
      const resolvedPath = path.resolve(targetPath);

      // Read directory entries
      const dirents = await fs.readdir(resolvedPath, { withFileTypes: true });

      // Filter and map entries
      const entries: FilesystemListDirResult['entries'] = [];

      for (const dirent of dirents) {
        // Skip hidden files unless requested
        if (!showHidden && dirent.name.startsWith('.')) {
          continue;
        }

        const entryPath = path.join(resolvedPath, dirent.name);
        const isDirectory = dirent.isDirectory();
        const isSymlink = dirent.isSymbolicLink();

        let size: number | undefined;
        let modifiedAt: string | undefined;

        // Only get stats for non-directories (to avoid permission errors on system dirs)
        if (!isDirectory) {
          try {
            const stats = await fs.stat(entryPath);
            size = stats.size;
            modifiedAt = stats.mtime.toISOString();
          } catch {
            // Skip if we can't read stats
          }
        }

        entries.push({
          name: dirent.name,
          path: entryPath,
          isDirectory,
          isSymlink,
          size,
          modifiedAt,
        });
      }

      // Sort: directories first, then alphabetically
      entries.sort((a, b) => {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
      });

      // Get parent path
      const parent = resolvedPath === path.parse(resolvedPath).root
        ? null
        : path.dirname(resolvedPath);

      const result: FilesystemListDirResult = {
        path: resolvedPath,
        parent,
        entries,
      };

      return this.successResponse(request.id, result);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to list directory';
      return this.errorResponse(request.id, 'FILESYSTEM_ERROR', message);
    }
  }

  private async handleFilesystemGetHome(request: RpcRequest): Promise<RpcResponse> {
    const homePath = os.homedir();

    // Common project directories to suggest
    const commonPaths = [
      { name: 'Home', path: homePath },
      { name: 'Desktop', path: path.join(homePath, 'Desktop') },
      { name: 'Documents', path: path.join(homePath, 'Documents') },
      { name: 'Downloads', path: path.join(homePath, 'Downloads') },
      { name: 'Projects', path: path.join(homePath, 'projects') },
      { name: 'Code', path: path.join(homePath, 'code') },
      { name: 'Development', path: path.join(homePath, 'Development') },
      { name: 'dev', path: path.join(homePath, 'dev') },
      { name: 'src', path: path.join(homePath, 'src') },
      { name: 'workspace', path: path.join(homePath, 'workspace') },
      { name: 'work', path: path.join(homePath, 'work') },
    ];

    // Check which paths exist
    const suggestedPaths = await Promise.all(
      commonPaths.map(async ({ name, path: dirPath }) => {
        try {
          const stat = await fs.stat(dirPath);
          return { name, path: dirPath, exists: stat.isDirectory() };
        } catch {
          return { name, path: dirPath, exists: false };
        }
      })
    );

    // Filter to only existing paths, but always include home
    const existingPaths = suggestedPaths.filter(p => p.exists || p.path === homePath);

    const result: FilesystemGetHomeResult = {
      homePath,
      suggestedPaths: existingPaths,
    };

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // System Handlers
  // ===========================================================================

  private async handleSystemPing(request: RpcRequest): Promise<RpcResponse> {
    const result: SystemPingResult = {
      pong: true,
      timestamp: new Date().toISOString(),
    };
    return this.successResponse(request.id, result);
  }

  private async handleSystemGetInfo(request: RpcRequest): Promise<RpcResponse> {
    const memory = process.memoryUsage();

    const result: SystemGetInfoResult = {
      version: VERSION,
      uptime: Date.now() - this.startTime,
      activeSessions: 0, // Would be populated by session manager
      memoryUsage: {
        heapUsed: memory.heapUsed,
        heapTotal: memory.heapTotal,
      },
    };

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Event Handlers
  // ===========================================================================

  private async handleEventsGetHistory(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { sessionId: string; types?: string[]; limit?: number; beforeEventId?: string } | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const result = await this.context.eventStore.getEventHistory(params.sessionId, {
      types: params.types,
      limit: params.limit,
      beforeEventId: params.beforeEventId,
    });

    return this.successResponse(request.id, result);
  }

  private async handleEventsGetSince(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { sessionId?: string; workspaceId?: string; afterEventId?: string; afterTimestamp?: string; limit?: number } | undefined;

    const result = await this.context.eventStore.getEventsSince({
      sessionId: params?.sessionId,
      workspaceId: params?.workspaceId,
      afterEventId: params?.afterEventId,
      afterTimestamp: params?.afterTimestamp,
      limit: params?.limit,
    });

    return this.successResponse(request.id, result);
  }

  private async handleEventsAppend(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { sessionId: string; type: string; payload: Record<string, unknown>; parentId?: string } | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params?.type) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'type is required');
    }
    if (!params?.payload) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'payload is required');
    }

    const result = await this.context.eventStore.appendEvent(
      params.sessionId,
      params.type,
      params.payload,
      params.parentId
    );

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Tree Handlers
  // ===========================================================================

  private async handleTreeGetVisualization(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { sessionId: string; maxDepth?: number; messagesOnly?: boolean } | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const result = await this.context.eventStore.getTreeVisualization(params.sessionId, {
      maxDepth: params.maxDepth,
      messagesOnly: params.messagesOnly,
    });

    return this.successResponse(request.id, result);
  }

  private async handleTreeGetBranches(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { sessionId: string } | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const result = await this.context.eventStore.getBranches(params.sessionId);
    return this.successResponse(request.id, result);
  }

  private async handleTreeGetSubtree(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { eventId: string; maxDepth?: number; direction?: 'descendants' | 'ancestors' } | undefined;

    if (!params?.eventId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'eventId is required');
    }

    const result = await this.context.eventStore.getSubtree(params.eventId, {
      maxDepth: params.maxDepth,
      direction: params.direction,
    });

    return this.successResponse(request.id, result);
  }

  private async handleTreeGetAncestors(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { eventId: string } | undefined;

    if (!params?.eventId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'eventId is required');
    }

    const result = await this.context.eventStore.getAncestors(params.eventId);
    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Search Handlers
  // ===========================================================================

  private async handleSearchContent(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { query: string; sessionId?: string; workspaceId?: string; types?: string[]; limit?: number } | undefined;

    if (!params?.query) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'query is required');
    }

    const result = await this.context.eventStore.searchContent(params.query, {
      sessionId: params.sessionId,
      workspaceId: params.workspaceId,
      types: params.types,
      limit: params.limit,
    });

    return this.successResponse(request.id, result);
  }

  private async handleSearchEvents(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.eventStore) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
    }

    const params = request.params as { query: string; sessionId?: string; workspaceId?: string; types?: string[]; limit?: number } | undefined;

    if (!params?.query) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'query is required');
    }

    const result = await this.context.eventStore.searchContent(params.query, {
      sessionId: params.sessionId,
      workspaceId: params.workspaceId,
      types: params.types,
      limit: params.limit,
    });

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Worktree Handlers
  // ===========================================================================

  private async handleWorktreeGetStatus(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.worktreeManager) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
    }

    const params = request.params as WorktreeGetStatusParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }

    const worktree = await this.context.worktreeManager.getWorktreeStatus(params.sessionId);

    const result: WorktreeGetStatusResult = {
      hasWorktree: worktree !== null,
      worktree: worktree ?? undefined,
    };

    return this.successResponse(request.id, result);
  }

  private async handleWorktreeCommit(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.worktreeManager) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
    }

    const params = request.params as WorktreeCommitParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params?.message) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'message is required');
    }

    const result: WorktreeCommitResult = await this.context.worktreeManager.commitWorktree(
      params.sessionId,
      params.message
    );

    return this.successResponse(request.id, result);
  }

  private async handleWorktreeMerge(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.worktreeManager) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
    }

    const params = request.params as WorktreeMergeParams | undefined;

    if (!params?.sessionId) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
    }
    if (!params?.targetBranch) {
      return this.errorResponse(request.id, 'INVALID_PARAMS', 'targetBranch is required');
    }

    const result: WorktreeMergeResult = await this.context.worktreeManager.mergeWorktree(
      params.sessionId,
      params.targetBranch,
      params.strategy
    );

    return this.successResponse(request.id, result);
  }

  private async handleWorktreeList(request: RpcRequest): Promise<RpcResponse> {
    if (!this.context.worktreeManager) {
      return this.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
    }

    const worktrees = await this.context.worktreeManager.listWorktrees();

    const result: WorktreeListResult = { worktrees };

    return this.successResponse(request.id, result);
  }

  // ===========================================================================
  // Response Helpers
  // ===========================================================================

  private successResponse<T>(id: string, result: T): RpcResponse<T> {
    return {
      id,
      success: true,
      result,
    };
  }

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
