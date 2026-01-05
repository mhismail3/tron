/**
 * @fileoverview EventStore-backed Session Orchestrator
 *
 * Manages multiple agent sessions using the EventStore for persistence.
 * This is the unified event-sourced architecture for session management.
 */
import { EventEmitter } from 'events';
import * as path from 'path';
import * as os from 'os';
import {
  createLogger,
  TronAgent,
  EventStore,
  WorktreeCoordinator,
  createWorktreeCoordinator,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  GrepTool,
  FindTool,
  LsTool,
  loadServerAuth,
  type AgentConfig,
  type TurnResult,
  type TronEvent,
  type TronTool,
  type EventMessage,
  type EventSessionState,
  type TronSessionEvent,
  type AppendEventOptions,
  type EventId,
  type SessionId,
  type WorkingDirectory,
  type WorktreeCoordinatorConfig,
  type ServerAuth,
} from '@tron/core';

const logger = createLogger('event-store-orchestrator');

// =============================================================================
// Default System Prompt
// =============================================================================

const DEFAULT_SYSTEM_PROMPT = `You are Tron, an AI coding assistant with full access to the user's file system.

You have access to the following tools:
- read: Read files from the file system
- write: Write content to files
- edit: Make targeted edits to existing files
- bash: Execute shell commands
- grep: Search for patterns in files
- find: Find files by name or pattern
- ls: List directory contents

When the user asks you to work with files or code, you can directly read, write, and edit files using these tools. You are operating on the server machine with full file system access.

Be helpful, accurate, and efficient. When working with code:
1. Read existing files to understand context before making changes
2. Make targeted, minimal edits rather than rewriting entire files
3. Test changes by running appropriate commands when asked
4. Explain what you're doing and why

Current working directory: {workingDirectory}
`;

// =============================================================================
// Types
// =============================================================================

export interface EventStoreOrchestratorConfig {
  /** Path to event store database (defaults to ~/.tron/events.db) */
  eventStoreDbPath?: string;
  /** Default model */
  defaultModel: string;
  /** Default provider */
  defaultProvider: string;
  /** Max concurrent sessions */
  maxConcurrentSessions?: number;
  /** Worktree configuration */
  worktree?: WorktreeCoordinatorConfig;
}

/**
 * Worktree status information for a session
 */
export interface WorktreeInfo {
  /** Whether this session uses an isolated worktree */
  isolated: boolean;
  /** Git branch name */
  branch: string;
  /** Base commit hash when worktree was created */
  baseCommit: string;
  /** Filesystem path to the working directory */
  path: string;
  /** Whether there are uncommitted changes */
  hasUncommittedChanges?: boolean;
  /** Number of commits since base */
  commitCount?: number;
}

export interface ActiveSession {
  sessionId: SessionId;
  agent: TronAgent;
  isProcessing: boolean;
  lastActivity: Date;
  workingDirectory: string;
  model: string;
  /** WorkingDirectory abstraction (if worktree coordination is enabled) */
  workingDir?: WorkingDirectory;
}

export interface AgentRunOptions {
  sessionId: string;
  prompt: string;
  onEvent?: (event: AgentEvent) => void;
}

export interface AgentEvent {
  type: 'text' | 'tool_start' | 'tool_end' | 'turn_complete' | 'error';
  sessionId: string;
  timestamp: string;
  data: unknown;
}

export interface CreateSessionOptions {
  workingDirectory: string;
  model?: string;
  provider?: string;
  title?: string;
  tags?: string[];
  systemPrompt?: string;
  /** Force worktree isolation even if not needed */
  forceIsolation?: boolean;
}

export interface SessionInfo {
  sessionId: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  eventCount: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  /** Worktree status (if worktree coordination is enabled) */
  worktree?: WorktreeInfo;
}

export interface ForkResult {
  newSessionId: string;
  rootEventId: string;
  forkedFromEventId: string;
  forkedFromSessionId: string;
  /** Worktree status for the forked session */
  worktree?: WorktreeInfo;
}

export interface RewindResult {
  sessionId: string;
  newHeadEventId: string;
  previousHeadEventId: string;
}

// =============================================================================
// EventStore Orchestrator
// =============================================================================

export class EventStoreOrchestrator extends EventEmitter {
  private config: EventStoreOrchestratorConfig;
  private eventStore: EventStore;
  private worktreeCoordinator: WorktreeCoordinator;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;
  private initialized = false;
  private cachedAuth: ServerAuth | null = null;

  constructor(config: EventStoreOrchestratorConfig) {
    super();
    this.config = config;

    // Default event store path
    const eventStoreDbPath = config.eventStoreDbPath ??
      path.join(os.homedir(), '.tron', 'events.db');

    // Initialize EventStore
    this.eventStore = new EventStore(eventStoreDbPath);

    // Initialize WorktreeCoordinator
    this.worktreeCoordinator = createWorktreeCoordinator(this.eventStore, {
      isolationMode: config.worktree?.isolationMode ?? 'lazy',
      branchPrefix: config.worktree?.branchPrefix ?? 'session/',
      autoCommitOnRelease: config.worktree?.autoCommitOnRelease ?? true,
      deleteWorktreeOnRelease: config.worktree?.deleteWorktreeOnRelease ?? true,
      preserveBranches: config.worktree?.preserveBranches ?? true,
      ...config.worktree,
    });
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  async initialize(): Promise<void> {
    if (this.initialized) return;

    // Load auth from ~/.tron/auth.json (supports Claude Max OAuth)
    // IMPORTANT: Does NOT check ANTHROPIC_API_KEY env var - that would override OAuth
    this.cachedAuth = await loadServerAuth();
    if (!this.cachedAuth) {
      logger.warn('No authentication configured - run tron login to authenticate');
    } else {
      logger.info('Authentication loaded', {
        type: this.cachedAuth.type,
        isOAuth: this.cachedAuth.type === 'oauth',
      });
    }

    await this.eventStore.initialize();
    this.startCleanupTimer();
    this.initialized = true;
    logger.info('EventStore orchestrator initialized');
  }

  async shutdown(): Promise<void> {
    this.stopCleanupTimer();

    // End all active sessions
    for (const [sessionId, _active] of this.activeSessions.entries()) {
      try {
        await this.endSession(sessionId);
      } catch (error) {
        logger.error('Failed to end session during shutdown', { sessionId, error });
      }
    }
    this.activeSessions.clear();

    await this.eventStore.close();
    this.initialized = false;
    logger.info('EventStore orchestrator shutdown complete');
  }

  // ===========================================================================
  // EventStore Access
  // ===========================================================================

  getEventStore(): EventStore {
    return this.eventStore;
  }

  // ===========================================================================
  // Session Management
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<SessionInfo> {
    const maxSessions = this.config.maxConcurrentSessions ?? 10;
    if (this.activeSessions.size >= maxSessions) {
      throw new Error(`Maximum concurrent sessions (${maxSessions}) reached`);
    }

    const model = options.model ?? this.config.defaultModel;
    const provider = options.provider ?? this.config.defaultProvider;

    // Create session in EventStore
    const result = await this.eventStore.createSession({
      workspacePath: options.workingDirectory,
      workingDirectory: options.workingDirectory,
      model,
      provider,
      title: options.title,
      tags: options.tags,
    });

    const sessionId = result.session.id;

    // Acquire working directory through coordinator
    const workingDir = await this.worktreeCoordinator.acquire(
      sessionId,
      options.workingDirectory,
      { forceIsolation: options.forceIsolation }
    );

    // Create agent for session (use the resolved working directory path)
    const agent = await this.createAgentForSession(
      sessionId,
      workingDir.path,
      model,
      options.systemPrompt
    );

    this.activeSessions.set(sessionId, {
      sessionId,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model,
      workingDir,
    });

    this.emit('session_created', {
      sessionId,
      workingDirectory: workingDir.path,
      model,
      worktree: this.buildWorktreeInfo(workingDir),
    });

    logger.info('Session created', {
      sessionId,
      isolated: workingDir.isolated,
      branch: workingDir.branch,
    });

    return this.sessionRowToInfo(result.session, true, workingDir);
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    // Check if already active
    const existing = this.activeSessions.get(sessionId);
    if (existing) {
      existing.lastActivity = new Date();
      const session = await this.eventStore.getSession(sessionId as SessionId);
      return this.sessionRowToInfo(session!, true, existing.workingDir);
    }

    // Load from EventStore
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Acquire working directory through coordinator
    const workingDir = await this.worktreeCoordinator.acquire(
      session.id,
      session.workingDirectory
    );

    // Create agent (use resolved working directory path)
    const agent = await this.createAgentForSession(
      session.id,
      workingDir.path,
      session.model
    );

    this.activeSessions.set(sessionId, {
      sessionId: session.id,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model: session.model,
      workingDir,
    });

    logger.info('Session resumed', {
      sessionId,
      isolated: workingDir.isolated,
    });
    return this.sessionRowToInfo(session, true, workingDir);
  }

  async endSession(sessionId: string, options?: {
    mergeTo?: string;
    mergeStrategy?: 'merge' | 'rebase' | 'squash';
    commitMessage?: string;
  }): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (active?.isProcessing) {
      throw new Error('Cannot end session while processing');
    }

    // Append session end event
    await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'session.end',
      payload: {
        reason: 'completed',
        timestamp: new Date().toISOString(),
      },
    });

    // Release working directory through coordinator
    await this.worktreeCoordinator.release(sessionId as SessionId, {
      mergeTo: options?.mergeTo,
      mergeStrategy: options?.mergeStrategy,
      commitMessage: options?.commitMessage,
    });

    await this.eventStore.endSession(sessionId as SessionId);
    this.activeSessions.delete(sessionId);

    this.emit('session_ended', { sessionId, reason: 'completed' });
    logger.info('Session ended', { sessionId });
  }

  async getSession(sessionId: string): Promise<SessionInfo | null> {
    const isActive = this.activeSessions.has(sessionId);
    const active = this.activeSessions.get(sessionId);
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) return null;
    return this.sessionRowToInfo(session, isActive, active?.workingDir);
  }

  async listSessions(options: {
    workingDirectory?: string;
    limit?: number;
    activeOnly?: boolean;
  }): Promise<SessionInfo[]> {
    if (options.activeOnly) {
      const active = Array.from(this.activeSessions.values())
        .filter(a => !options.workingDirectory || a.workingDirectory === options.workingDirectory)
        .slice(0, options.limit ?? 50);

      const sessions: SessionInfo[] = [];
      for (const a of active) {
        const session = await this.eventStore.getSession(a.sessionId);
        if (session) {
          sessions.push(this.sessionRowToInfo(session, true, a.workingDir));
        }
      }
      return sessions;
    }

    // Note: The EventStore uses workspaceId, but for convenience we filter by working directory
    // after fetching. In production, we'd look up workspaceId first.
    const sessionRows = await this.eventStore.listSessions({
      limit: options.limit,
    });

    // Filter by working directory if specified
    const filtered = options.workingDirectory
      ? sessionRows.filter(row => row.workingDirectory === options.workingDirectory)
      : sessionRows;

    return filtered.map(row => {
      const active = this.activeSessions.get(row.id);
      return this.sessionRowToInfo(row, !!active, active?.workingDir);
    });
  }

  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.activeSessions.get(sessionId);
  }

  // ===========================================================================
  // Fork & Rewind
  // ===========================================================================

  async forkSession(sessionId: string, fromEventId?: string): Promise<ForkResult> {
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const eventIdToFork = fromEventId
      ? fromEventId as EventId
      : session.headEventId!;

    const result = await this.eventStore.fork(eventIdToFork, {
      name: `Fork of ${session.title || sessionId}`,
    });

    // Get parent's working directory to determine commit to branch from
    const parentActive = this.activeSessions.get(sessionId);
    let parentCommit: string | undefined;
    if (parentActive?.workingDir) {
      try {
        parentCommit = await parentActive.workingDir.getCurrentCommit();
      } catch {
        // Ignore if we can't get commit
      }
    }

    // Acquire isolated worktree for forked session
    const workingDir = await this.worktreeCoordinator.acquire(
      result.session.id,
      session.workingDirectory,
      {
        parentSessionId: sessionId as SessionId,
        parentCommit,
        forceIsolation: true,
      }
    );

    this.emit('session_forked', {
      sourceSessionId: sessionId,
      sourceEventId: eventIdToFork,
      newSessionId: result.session.id,
      newRootEventId: result.rootEvent.id,
      worktree: this.buildWorktreeInfo(workingDir),
    });

    logger.info('Session forked', {
      original: sessionId,
      forked: result.session.id,
      isolated: workingDir.isolated,
      branch: workingDir.branch,
    });

    return {
      newSessionId: result.session.id,
      rootEventId: result.rootEvent.id,
      forkedFromEventId: eventIdToFork,
      forkedFromSessionId: sessionId,
      worktree: this.buildWorktreeInfo(workingDir),
    };
  }

  async rewindSession(sessionId: string, toEventId: string): Promise<RewindResult> {
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const previousHeadEventId = session.headEventId!;

    await this.eventStore.rewind(sessionId as SessionId, toEventId as EventId);

    // If this is an active session, refresh the cached data
    const active = this.activeSessions.get(sessionId);
    if (active) {
      active.lastActivity = new Date();
    }

    this.emit('session_rewound', {
      sessionId,
      previousHeadEventId,
      newHeadEventId: toEventId,
    });

    logger.info('Session rewound', { sessionId, toEventId });

    return {
      sessionId,
      newHeadEventId: toEventId,
      previousHeadEventId,
    };
  }

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  async getSessionState(sessionId: string, atEventId?: string): Promise<EventSessionState> {
    if (atEventId) {
      return this.eventStore.getStateAt(atEventId as EventId);
    }
    return this.eventStore.getStateAtHead(sessionId as SessionId);
  }

  async getSessionMessages(sessionId: string, atEventId?: string): Promise<EventMessage[]> {
    if (atEventId) {
      return this.eventStore.getMessagesAt(atEventId as EventId);
    }
    return this.eventStore.getMessagesAtHead(sessionId as SessionId);
  }

  async getSessionEvents(sessionId: string): Promise<TronSessionEvent[]> {
    return this.eventStore.getEventsBySession(sessionId as SessionId);
  }

  async getAncestors(eventId: string): Promise<TronSessionEvent[]> {
    return this.eventStore.getAncestors(eventId as EventId);
  }

  async appendEvent(options: AppendEventOptions): Promise<TronSessionEvent> {
    const event = await this.eventStore.append(options);

    // Broadcast event to subscribers
    this.emit('event_new', {
      event,
      sessionId: options.sessionId,
    });

    return event;
  }

  // ===========================================================================
  // Agent Operations
  // ===========================================================================

  async runAgent(options: AgentRunOptions): Promise<TurnResult[]> {
    const active = this.activeSessions.get(options.sessionId);
    if (!active) {
      throw new Error(`Session not active: ${options.sessionId}`);
    }

    if (active.isProcessing) {
      throw new Error('Session is already processing');
    }

    active.isProcessing = true;
    active.lastActivity = new Date();

    try {
      // Record user message event
      await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.user',
        payload: { content: options.prompt },
      });

      // Run agent
      const runResult = await active.agent.run(options.prompt);
      active.lastActivity = new Date();

      // Record assistant response event
      // Get the last assistant message from the run result
      const lastAssistantMessage = runResult.messages
        .filter(m => m.role === 'assistant')
        .at(-1);

      await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.assistant',
        payload: {
          content: lastAssistantMessage?.content || [],
          tokenUsage: runResult.totalTokenUsage,
        },
      });

      // Emit completion event
      this.emit('agent_turn', {
        type: 'turn_complete',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        data: runResult,
      });

      if (options.onEvent) {
        options.onEvent({
          type: 'turn_complete',
          sessionId: options.sessionId,
          timestamp: new Date().toISOString(),
          data: runResult,
        });
      }

      return [runResult] as unknown as TurnResult[];
    } catch (error) {
      logger.error('Agent run error', { sessionId: options.sessionId, error });

      if (options.onEvent) {
        options.onEvent({
          type: 'error',
          sessionId: options.sessionId,
          timestamp: new Date().toISOString(),
          data: { message: error instanceof Error ? error.message : 'Unknown error' },
        });
      }

      throw error;
    } finally {
      active.isProcessing = false;
    }
  }

  async cancelAgent(sessionId: string): Promise<boolean> {
    const active = this.activeSessions.get(sessionId);
    if (!active || !active.isProcessing) {
      return false;
    }

    active.isProcessing = false;
    logger.info('Agent cancelled', { sessionId });
    return true;
  }

  // ===========================================================================
  // Model Switching
  // ===========================================================================

  async switchModel(sessionId: string, model: string): Promise<{ previousModel: string; newModel: string }> {
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const previousModel = session.model;

    // Record model switch event
    await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'config.model_switch',
      payload: {
        previousModel,
        newModel: model,
      },
    });

    // Update active session if exists
    const active = this.activeSessions.get(sessionId);
    if (active) {
      active.model = model;
      active.agent = await this.createAgentForSession(
        active.sessionId,
        active.workingDirectory,
        model
      );
    }

    logger.info('Model switched', { sessionId, previousModel, newModel: model });

    return { previousModel, newModel: model };
  }

  // ===========================================================================
  // Search
  // ===========================================================================

  async searchEvents(query: string, options?: {
    workspaceId?: string;
    sessionId?: string;
    types?: string[];
    limit?: number;
  }) {
    return this.eventStore.search(query, options as any);
  }

  // ===========================================================================
  // Health & Stats
  // ===========================================================================

  getHealth(): {
    status: 'healthy' | 'degraded' | 'unhealthy';
    activeSessions: number;
    processingSessions: number;
    uptime: number;
  } {
    const processingSessions = Array.from(this.activeSessions.values())
      .filter(a => a.isProcessing).length;

    return {
      status: 'healthy',
      activeSessions: this.activeSessions.size,
      processingSessions,
      uptime: process.uptime(),
    };
  }

  // ===========================================================================
  // Worktree Operations
  // ===========================================================================

  /**
   * Get worktree status for a session
   */
  async getWorktreeStatus(sessionId: string): Promise<WorktreeInfo | null> {
    const active = this.activeSessions.get(sessionId);
    if (!active?.workingDir) {
      return null;
    }

    return this.buildWorktreeInfoWithStatus(active.workingDir);
  }

  /**
   * Commit changes in a session's worktree
   */
  async commitWorktree(sessionId: string, message: string): Promise<{
    success: boolean;
    commitHash?: string;
    filesChanged?: string[];
    error?: string;
  }> {
    const active = this.activeSessions.get(sessionId);
    if (!active?.workingDir) {
      return { success: false, error: 'Session not found or no worktree' };
    }

    try {
      const result = await active.workingDir.commit(message, { addAll: true });
      if (!result) {
        return { success: true, filesChanged: [] }; // Nothing to commit
      }

      return {
        success: true,
        commitHash: result.hash,
        filesChanged: result.filesChanged,
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  /**
   * Merge a session's worktree to a target branch
   */
  async mergeWorktree(sessionId: string, targetBranch: string, strategy?: 'merge' | 'rebase' | 'squash'): Promise<{
    success: boolean;
    mergeCommit?: string;
    conflicts?: string[];
  }> {
    return this.worktreeCoordinator.mergeSession(
      sessionId as SessionId,
      targetBranch,
      strategy || 'merge'
    );
  }

  /**
   * Get the WorktreeCoordinator (for advanced use cases)
   */
  getWorktreeCoordinator(): WorktreeCoordinator {
    return this.worktreeCoordinator;
  }

  /**
   * List all worktrees
   */
  async listWorktrees(): Promise<Array<{ path: string; branch: string; sessionId?: string }>> {
    return this.worktreeCoordinator.listWorktrees();
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string
  ): Promise<TronAgent> {
    // Use cached auth from ~/.tron/auth.json (supports Claude Max OAuth)
    // Refresh cache if needed (OAuth tokens expire)
    if (!this.cachedAuth || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
      this.cachedAuth = await loadServerAuth();
    }

    if (!this.cachedAuth) {
      throw new Error('No authentication configured. Run `tron login` to authenticate with Claude Max or set up API key.');
    }

    const tools: TronTool[] = [
      new ReadTool({ workingDirectory }),
      new WriteTool({ workingDirectory }),
      new EditTool({ workingDirectory }),
      new BashTool({ workingDirectory }),
      new GrepTool({ workingDirectory }),
      new FindTool({ workingDirectory }),
      new LsTool({ workingDirectory }),
    ];

    const prompt = systemPrompt ||
      DEFAULT_SYSTEM_PROMPT.replace('{workingDirectory}', workingDirectory);

    logger.info('Creating agent with tools', {
      sessionId,
      workingDirectory,
      toolCount: tools.length,
      authType: this.cachedAuth.type,
      isOAuth: this.cachedAuth.type === 'oauth',
    });

    const agentConfig: AgentConfig = {
      provider: {
        model,
        auth: this.cachedAuth, // Use OAuth or API key from ~/.tron/auth.json
      },
      tools,
      systemPrompt: prompt,
      maxTurns: 50,
    };

    const agent = new TronAgent(agentConfig, {
      sessionId,
      workingDirectory,
    });

    agent.onEvent((event) => {
      this.forwardAgentEvent(sessionId, event);
    });

    return agent;
  }

  private forwardAgentEvent(sessionId: SessionId, event: TronEvent): void {
    const timestamp = new Date().toISOString();

    switch (event.type) {
      case 'turn_start':
        this.emit('agent_event', {
          type: 'agent.turn_start',
          sessionId,
          timestamp,
          data: { turn: event.turn },
        });
        break;

      case 'turn_end':
        this.emit('agent_event', {
          type: 'agent.turn_end',
          sessionId,
          timestamp,
          data: {
            turn: event.turn,
            duration: event.duration,
            tokenUsage: event.tokenUsage,
          },
        });
        break;

      case 'message_update':
        this.emit('agent_event', {
          type: 'agent.text_delta',
          sessionId,
          timestamp,
          data: { delta: event.content },
        });
        break;

      case 'tool_execution_start':
        this.emit('agent_event', {
          type: 'agent.tool_start',
          sessionId,
          timestamp,
          data: {
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.arguments,
          },
        });
        break;

      case 'tool_execution_end': {
        const resultContent = typeof event.result === 'object' && event.result !== null
          ? (event.result as { content?: string }).content ?? JSON.stringify(event.result)
          : String(event.result ?? '');

        this.emit('agent_event', {
          type: 'agent.tool_end',
          sessionId,
          timestamp,
          data: {
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            success: !event.isError,
            output: event.isError ? undefined : resultContent,
            error: event.isError ? resultContent : undefined,
            duration: event.duration,
          },
        });
        break;
      }

      case 'agent_start':
        this.emit('agent_event', {
          type: 'agent.turn_start',
          sessionId,
          timestamp,
          data: {},
        });
        break;

      case 'agent_end':
        this.emit('agent_event', {
          type: 'agent.complete',
          sessionId,
          timestamp,
          data: {
            success: !event.error,
            error: event.error,
          },
        });
        break;

      case 'agent_interrupted':
        this.emit('agent_event', {
          type: 'agent.complete',
          sessionId,
          timestamp,
          data: {
            success: false,
            interrupted: true,
            partialContent: event.partialContent,
          },
        });
        break;
    }
  }

  private sessionRowToInfo(
    row: any,
    isActive: boolean,
    workingDir?: WorkingDirectory
  ): SessionInfo {
    return {
      sessionId: row.id,
      workingDirectory: workingDir?.path ?? row.workingDirectory,
      model: row.model,
      messageCount: row.messageCount ?? 0,
      eventCount: row.eventCount ?? 0,
      createdAt: row.createdAt,
      lastActivity: row.lastActivityAt,
      isActive,
      worktree: workingDir ? this.buildWorktreeInfo(workingDir) : undefined,
    };
  }

  /**
   * Build WorktreeInfo from a WorkingDirectory
   */
  private buildWorktreeInfo(workingDir: WorkingDirectory): WorktreeInfo {
    return {
      isolated: workingDir.isolated,
      branch: workingDir.branch,
      baseCommit: workingDir.baseCommit,
      path: workingDir.path,
    };
  }

  /**
   * Build WorktreeInfo with additional status (async)
   */
  private async buildWorktreeInfoWithStatus(workingDir: WorkingDirectory): Promise<WorktreeInfo> {
    const info = this.buildWorktreeInfo(workingDir);

    try {
      info.hasUncommittedChanges = await workingDir.hasUncommittedChanges();
      const commits = await workingDir.getCommitsSinceBase();
      info.commitCount = commits.length;
    } catch {
      // Ignore errors getting status
    }

    return info;
  }

  private startCleanupTimer(): void {
    this.cleanupTimer = setInterval(() => {
      this.cleanupInactiveSessions();
    }, 5 * 60 * 1000);
  }

  private stopCleanupTimer(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }

  private cleanupInactiveSessions(): void {
    const inactiveThreshold = 30 * 60 * 1000; // 30 minutes
    const now = Date.now();

    for (const [sessionId, active] of this.activeSessions.entries()) {
      if (active.isProcessing) continue;

      const inactiveTime = now - active.lastActivity.getTime();
      if (inactiveTime > inactiveThreshold) {
        logger.info('Cleaning up inactive session', {
          sessionId,
          inactiveMinutes: Math.floor(inactiveTime / 60000),
        });
        this.activeSessions.delete(sessionId);
      }
    }
  }
}
