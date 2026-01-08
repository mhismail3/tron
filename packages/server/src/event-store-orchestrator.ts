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
  type EventType,
  type CurrentTurnToolCall,
} from '@tron/core';
import { normalizeContentBlocks } from './utils/content-normalizer';

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
  /** Pre-existing EventStore instance (for testing) - if provided, eventStoreDbPath is ignored */
  eventStore?: EventStore;
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
  /** Current turn number (tracked for discrete event storage) */
  currentTurn: number;
  /**
   * In-memory head event ID for linearizing event appends.
   * Updated synchronously BEFORE async DB writes to prevent race conditions
   * where multiple rapid events all read the same headEventId from DB.
   */
  pendingHeadEventId: EventId | null;
  /**
   * Promise chain that serializes event appends for this session.
   * Each append chains to the previous one, ensuring ordered persistence.
   */
  appendPromiseChain: Promise<void>;
  /**
   * P0 FIX: Track append errors to prevent malformed event trees.
   * If an append fails, subsequent appends are skipped to preserve chain integrity.
   */
  lastAppendError?: Error;
  /**
   * Accumulated text content from ALL turns in the current agent run.
   * Used to provide catch-up content when client resumes into running session.
   * Cleared at agent_start, accumulated on message_update across all turns,
   * cleared at agent_end. NOT reset at turn boundaries so resuming during
   * Turn N shows content from Turn 1, 2, ..., N.
   */
  currentTurnAccumulatedText: string;
  /**
   * Tool calls from ALL turns in the current agent run.
   * Used to provide catch-up content when client resumes into running session.
   * Cleared at agent_start, updated on tool_start/tool_end across all turns,
   * cleared at agent_end. NOT reset at turn boundaries so resuming during
   * Turn N shows tools from Turn 1, 2, ..., N.
   */
  currentTurnToolCalls: CurrentTurnToolCall[];
  /**
   * Content sequence tracking the order of text and tool calls.
   * Each entry is either {type: 'text', text: string} or {type: 'tool_ref', toolCallId: string}.
   * This preserves the interleaving order for proper reconstruction on interrupt.
   */
  currentTurnContentSequence: Array<{type: 'text', text: string} | {type: 'tool_ref', toolCallId: string}>;
  /**
   * Flag indicating if this session was interrupted by user.
   * Used to inform clients that the session ended due to interruption.
   */
  wasInterrupted?: boolean;
}

export interface AgentRunOptions {
  sessionId: string;
  prompt: string;
  onEvent?: (event: AgentEvent) => void;
}

export interface AgentEvent {
  type: 'text' | 'tool_start' | 'tool_end' | 'turn_complete' | 'turn_interrupted' | 'error';
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
  inputTokens: number;
  outputTokens: number;
  cost: number;
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

    // Use injected EventStore (for testing) or create new one
    if (config.eventStore) {
      this.eventStore = config.eventStore;
    } else {
      const eventStoreDbPath = config.eventStoreDbPath ??
        path.join(os.homedir(), '.tron', 'events.db');
      this.eventStore = new EventStore(eventStoreDbPath);
    }

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
      currentTurn: 0,
      // Initialize linearization tracking with root event as head
      pendingHeadEventId: result.rootEvent.id,
      appendPromiseChain: Promise.resolve(),
      // Initialize current turn tracking for resume support
      currentTurnAccumulatedText: '',
      currentTurnToolCalls: [],
      currentTurnContentSequence: [],
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
      currentTurn: session.turnCount ?? 0,
      // Initialize linearization tracking from session's current head
      pendingHeadEventId: session.headEventId ?? null,
      appendPromiseChain: Promise.resolve(),
      // Initialize current turn tracking for resume support
      currentTurnAccumulatedText: '',
      currentTurnToolCalls: [],
      currentTurnContentSequence: [],
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

    // Chain the session.end event append to ensure proper linearization
    // CRITICAL: Previous code had the same race condition as switchModel() where
    // concurrent calls could capture the same pendingHeadEventId
    if (active) {
      const appendPromise = active.appendPromiseChain.then(async () => {
        // Capture parent ID INSIDE the chain callback - after previous events complete
        const parentId = active.pendingHeadEventId ?? undefined;

        const event = await this.eventStore.append({
          sessionId: sessionId as SessionId,
          type: 'session.end',
          payload: {
            reason: 'completed',
            timestamp: new Date().toISOString(),
          },
          parentId,
        });

        active.pendingHeadEventId = event.id;
        logger.debug('[LINEARIZE] session.end appended', {
          sessionId,
          eventId: event.id,
          parentId,
        });
      });

      // Update the chain and wait for this specific event
      active.appendPromiseChain = appendPromise;
      await appendPromise;
    } else {
      // Session not active - direct append is safe (no concurrent events)
      const event = await this.eventStore.append({
        sessionId: sessionId as SessionId,
        type: 'session.end',
        payload: {
          reason: 'completed',
          timestamp: new Date().toISOString(),
        },
      });
      logger.debug('[LINEARIZE] session.end appended (inactive session)', {
        sessionId,
        eventId: event.id,
        parentId: event.parentId,
      });
    }

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

      // P2 FIX: Batch fetch sessions to prevent N+1 queries
      const sessionIds = active.map(a => a.sessionId);
      const sessionsMap = await this.eventStore.getSessionsByIds(sessionIds);

      const sessions: SessionInfo[] = [];
      for (const a of active) {
        const session = sessionsMap.get(a.sessionId);
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

  /**
   * Check if a session was interrupted by looking at the last assistant message.
   * Returns true if the session's last assistant message has interrupted: true in payload.
   */
  async wasSessionInterrupted(sessionId: string): Promise<boolean> {
    try {
      // Get all events for the session
      const events = await this.eventStore.getEventsBySession(sessionId as SessionId);

      // Find the last message.assistant event
      for (let i = events.length - 1; i >= 0; i--) {
        const event = events[i];
        if (event && event.type === 'message.assistant') {
          const payload = event.payload as Record<string, unknown>;
          return payload?.interrupted === true;
        }
      }
      return false;
    } catch (error) {
      logger.error('Failed to check session interrupted status', { sessionId, error });
      return false;
    }
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

    // P0 FIX: Prevent rewind during active agent processing
    // Rewinding pendingHeadEventId while stream events are queued would cause
    // queued events to chain to rewind point instead of being abandoned
    const active = this.activeSessions.get(sessionId);
    if (active?.isProcessing) {
      throw new Error('Cannot rewind session while agent is processing');
    }

    const previousHeadEventId = session.headEventId!;

    await this.eventStore.rewind(sessionId as SessionId, toEventId as EventId);

    // If this is an active session, refresh the cached data
    // CRITICAL: Sync in-memory head after rewind to prevent race conditions
    // Without this, the next event would chain to the old head instead of rewind point
    if (active) {
      active.lastActivity = new Date();
      active.pendingHeadEventId = toEventId as EventId;
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
      // CRITICAL: Wait for any pending stream events to complete before appending message events
      // This prevents race conditions where stream events (turn_start, etc.) capture wrong parentId
      await active.appendPromiseChain;

      // Record user message event (linearized to prevent spurious branches)
      // CRITICAL: Pass parentId from in-memory state, then update it after append
      const userMsgParentId = active.pendingHeadEventId ?? undefined;
      const userMsgEvent = await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.user',
        payload: { content: options.prompt },
        parentId: userMsgParentId,
      });
      active.pendingHeadEventId = userMsgEvent.id;
      logger.debug('[LINEARIZE] message.user appended', {
        sessionId: active.sessionId,
        eventId: userMsgEvent.id,
        parentId: userMsgParentId,
      });

      // Track timing for latency measurement (Phase 1)
      const runStartTime = Date.now();

      // Run agent
      const runResult = await active.agent.run(options.prompt);
      active.lastActivity = new Date();

      // Handle interrupted runs - PERSIST partial content so it survives session resume
      if (runResult.interrupted) {
        logger.info('Agent run interrupted', {
          sessionId: options.sessionId,
          turn: runResult.turns,
          hasPartialContent: !!runResult.partialContent,
          accumulatedTextLength: active.currentTurnAccumulatedText?.length ?? 0,
          toolCallsCount: active.currentTurnToolCalls?.length ?? 0,
        });

        // Notify the RPC caller (if any) about the interruption
        if (options.onEvent) {
          options.onEvent({
            type: 'turn_interrupted',
            sessionId: options.sessionId,
            timestamp: new Date().toISOString(),
            data: {
              interrupted: true,
              partialContent: runResult.partialContent,
            },
          });
        }

        // CRITICAL: Persist partial content so it survives session resume
        // Build content from the content sequence to preserve exact interleaving order
        // The sequence tracks text and tool_refs in the order they were received
        const assistantContent: any[] = [];
        const toolResultContent: any[] = [];

        // Build a lookup map for tool calls by ID for efficient access
        const toolCallMap = new Map<string, CurrentTurnToolCall>();
        if (active.currentTurnToolCalls) {
          for (const tc of active.currentTurnToolCalls) {
            toolCallMap.set(tc.toolCallId, tc);
          }
        }

        // Iterate through the content sequence to preserve exact order
        // This ensures text and tools appear in the same order as they were displayed
        if (active.currentTurnContentSequence && active.currentTurnContentSequence.length > 0) {
          for (const item of active.currentTurnContentSequence) {
            if (item.type === 'text') {
              // Add text block directly
              if (item.text) {
                assistantContent.push({ type: 'text', text: item.text });
              }
            } else if (item.type === 'tool_ref') {
              // Look up the tool call and add tool_use block
              const tc = toolCallMap.get(item.toolCallId);
              if (tc) {
                // Calculate duration if we have timing info
                const durationMs = tc.completedAt && tc.startedAt
                  ? new Date(tc.completedAt).getTime() - new Date(tc.startedAt).getTime()
                  : undefined;

                // Add tool_use block with status metadata
                // Mark interrupted tools so iOS can show red X
                const isInterrupted = tc.status === 'running' || tc.status === 'pending';
                assistantContent.push({
                  type: 'tool_use',
                  id: tc.toolCallId,
                  name: tc.toolName,
                  input: tc.arguments,
                  // Extended metadata for comprehensive ledger
                  _meta: {
                    status: tc.status,
                    interrupted: isInterrupted,
                    durationMs,
                  },
                });

                // Add tool_result for completed/error tools
                // This ensures results are visible when session is restored
                if (tc.status === 'completed' || tc.status === 'error') {
                  toolResultContent.push({
                    type: 'tool_result',
                    tool_use_id: tc.toolCallId,
                    content: tc.result ?? (tc.isError ? 'Error' : '(no output)'),
                    is_error: tc.isError ?? false,
                    // Extended metadata
                    _meta: {
                      durationMs,
                      toolName: tc.toolName,
                    },
                  });
                } else if (isInterrupted) {
                  // Add interrupted tool_result so the UI shows "interrupted" message
                  toolResultContent.push({
                    type: 'tool_result',
                    tool_use_id: tc.toolCallId,
                    content: 'Command interrupted (no output captured)',
                    is_error: false,
                    _meta: {
                      interrupted: true,
                      durationMs,
                      toolName: tc.toolName,
                    },
                  });
                }
              }
            }
          }
        } else {
          // Fallback: If no sequence tracking, use old method (text first, then tools)
          // This handles edge cases where sequence wasn't populated
          const partialText = active.currentTurnAccumulatedText || runResult.partialContent || '';
          if (partialText) {
            assistantContent.push({ type: 'text', text: partialText });
          }

          for (const tc of toolCallMap.values()) {
            const durationMs = tc.completedAt && tc.startedAt
              ? new Date(tc.completedAt).getTime() - new Date(tc.startedAt).getTime()
              : undefined;

            const isInterrupted = tc.status === 'running' || tc.status === 'pending';
            assistantContent.push({
              type: 'tool_use',
              id: tc.toolCallId,
              name: tc.toolName,
              input: tc.arguments,
              _meta: {
                status: tc.status,
                interrupted: isInterrupted,
                durationMs,
              },
            });

            if (tc.status === 'completed' || tc.status === 'error') {
              toolResultContent.push({
                type: 'tool_result',
                tool_use_id: tc.toolCallId,
                content: tc.result ?? (tc.isError ? 'Error' : '(no output)'),
                is_error: tc.isError ?? false,
                _meta: { durationMs, toolName: tc.toolName },
              });
            } else if (isInterrupted) {
              toolResultContent.push({
                type: 'tool_result',
                tool_use_id: tc.toolCallId,
                content: 'Command interrupted (no output captured)',
                is_error: false,
                _meta: { interrupted: true, durationMs, toolName: tc.toolName },
              });
            }
          }
        }

        // Only persist if there's actual content
        if (assistantContent.length > 0 || toolResultContent.length > 0) {
          // Wait for any pending stream events
          await active.appendPromiseChain;

          // 1. Persist assistant message with tool_use blocks
          if (assistantContent.length > 0) {
            const normalizedAssistantContent = normalizeContentBlocks(assistantContent);
            const assistantParentId = active.pendingHeadEventId;

            const assistantMsgEvent = await this.eventStore.append({
              sessionId: active.sessionId,
              type: 'message.assistant',
              payload: {
                content: normalizedAssistantContent,
                tokenUsage: runResult.totalTokenUsage,
                turn: runResult.turns || 1,
                model: active.model,
                stopReason: 'interrupted',
                interrupted: true,
              },
              parentId: assistantParentId,
            });
            active.pendingHeadEventId = assistantMsgEvent.id;

            logger.info('Persisted interrupted assistant message', {
              sessionId: active.sessionId,
              eventId: assistantMsgEvent.id,
              contentBlocks: normalizedAssistantContent.length,
              sequenceItems: active.currentTurnContentSequence?.length ?? 0,
              toolCalls: active.currentTurnToolCalls?.length ?? 0,
            });
          }

          // 2. Persist tool results as user message (like normal flow)
          // This ensures tool results appear in the session history
          if (toolResultContent.length > 0) {
            const normalizedToolResults = normalizeContentBlocks(toolResultContent);
            const toolResultParentId = active.pendingHeadEventId;

            const toolResultEvent = await this.eventStore.append({
              sessionId: active.sessionId,
              type: 'message.user',
              payload: { content: normalizedToolResults },
              parentId: toolResultParentId,
            });
            active.pendingHeadEventId = toolResultEvent.id;

            logger.info('Persisted tool results for interrupted session', {
              sessionId: active.sessionId,
              eventId: toolResultEvent.id,
              resultCount: normalizedToolResults.length,
            });
          }
        }

        // Persist notification.interrupted event as first-class ledger entry
        const interruptedNotificationParentId = active.pendingHeadEventId;
        const interruptNotificationEvent = await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'notification.interrupted',
          payload: {
            timestamp: new Date().toISOString(),
            turn: runResult.turns || 1,
          },
          parentId: interruptedNotificationParentId,
        });
        active.pendingHeadEventId = interruptNotificationEvent.id;

        logger.info('Persisted notification.interrupted event', {
          sessionId: active.sessionId,
          eventId: interruptNotificationEvent.id,
        });

        // Mark session as interrupted in metadata
        active.wasInterrupted = true;

        // Clear turn tracking state
        active.currentTurnAccumulatedText = '';
        active.currentTurnToolCalls = [];
        active.currentTurnContentSequence = [];

        return [runResult] as unknown as TurnResult[];
      }

      // Calculate latency (Phase 1)
      const runLatency = Date.now() - runStartTime;

      // Record assistant response event
      // Use currentTurnContentSequence if available - it preserves exact streaming order
      // This ensures text and tool_use blocks appear in the same order as they streamed
      let currentTurnContent: any[] = [];

      if (active.currentTurnContentSequence && active.currentTurnContentSequence.length > 0) {
        // Build content from the streaming sequence (preserves interleaving order)
        const toolCallMap = new Map<string, CurrentTurnToolCall>();
        if (active.currentTurnToolCalls) {
          for (const tc of active.currentTurnToolCalls) {
            toolCallMap.set(tc.toolCallId, tc);
          }
        }

        for (const item of active.currentTurnContentSequence) {
          if (item.type === 'text') {
            if (item.text) {
              currentTurnContent.push({ type: 'text', text: item.text });
            }
          } else if (item.type === 'tool_ref') {
            const tc = toolCallMap.get(item.toolCallId);
            if (tc) {
              currentTurnContent.push({
                type: 'tool_use',
                id: tc.toolCallId,
                name: tc.toolName,
                input: tc.arguments,
              });
            }
          }
        }

        logger.debug('Using currentTurnContentSequence for assistant content', {
          sessionId: active.sessionId,
          sequenceLength: active.currentTurnContentSequence.length,
          resultBlocks: currentTurnContent.length,
        });
      } else {
        // Fallback: use runResult.messages (may not preserve exact interleaving)
        let lastUserIndex = -1;
        for (let i = runResult.messages.length - 1; i >= 0; i--) {
          const msg = runResult.messages[i];
          if (msg && msg.role === 'user') {
            lastUserIndex = i;
            break;
          }
        }

        const currentTurnAssistantMessages = runResult.messages
          .slice(lastUserIndex + 1)
          .filter((m: any) => m.role === 'assistant');

        currentTurnContent = currentTurnAssistantMessages.flatMap((m: any) =>
          Array.isArray(m.content) ? m.content : [{ type: 'text' as const, text: String(m.content) }]
        );

        logger.debug('Using runResult.messages fallback for assistant content', {
          sessionId: active.sessionId,
          assistantMessages: currentTurnAssistantMessages.length,
          resultBlocks: currentTurnContent.length,
        });
      }

      // DEBUG: Log RAW content blocks BEFORE normalization
      const toolUseBlocks = currentTurnContent.filter((b: any) => b.type === 'tool_use');
      logger.debug('RAW assistant content before normalization', {
        sessionId: active.sessionId,
        totalBlocks: currentTurnContent.length,
        toolUseBlocks: toolUseBlocks.length,
        toolUseDetails: toolUseBlocks.map((b: any) => ({
          name: b.name,
          id: typeof b.id === 'string' ? b.id.slice(0, 20) + '...' : 'N/A',
          hasInputKey: 'input' in b,
          inputType: typeof b.input,
          inputIsObject: b.input !== null && typeof b.input === 'object',
          inputKeys: b.input && typeof b.input === 'object' ? Object.keys(b.input) : [],
          inputPreview: b.input ? JSON.stringify(b.input).slice(0, 150) : 'undefined/null',
        })),
      });

      // Normalize content blocks to ensure consistent structure and apply truncation
      const normalizedAssistantContent = normalizeContentBlocks(currentTurnContent);

      // Detect if content has thinking blocks (Phase 1)
      const hasThinking = currentTurnContent.some((b: any) => b.type === 'thinking');

      logger.debug('Storing assistant content', {
        sessionId: active.sessionId,
        blockCount: normalizedAssistantContent.length,
        blockTypes: normalizedAssistantContent.map(b => b.type),
        toolUseCount: normalizedAssistantContent.filter(b => b.type === 'tool_use').length,
        hasInputs: normalizedAssistantContent
          .filter(b => b.type === 'tool_use')
          .map(b => ({ name: b.name, hasInput: !!b.input && Object.keys(b.input as object).length > 0 })),
        // Phase 1 enrichment logging
        turn: runResult.turns,
        model: active.model,
        stopReason: runResult.stoppedReason,
        latency: runLatency,
        hasThinking,
      });

      // Phase 1: Store enriched assistant message with all metadata (linearized)
      // CRITICAL: Wait for stream events (turn_start, tool events, turn_end) to complete
      await active.appendPromiseChain;
      // CRITICAL: Pass parentId from in-memory state, then update it after append
      const assistantMsgParentId = active.pendingHeadEventId;
      const assistantMsgEvent = await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.assistant',
        payload: {
          content: normalizedAssistantContent,
          tokenUsage: runResult.totalTokenUsage,
          // Phase 1: Enriched fields
          turn: runResult.turns,
          model: active.model,
          stopReason: runResult.stoppedReason ?? 'end_turn',
          latency: runLatency,
          hasThinking,
        },
        parentId: assistantMsgParentId,
      });
      active.pendingHeadEventId = assistantMsgEvent.id;
      logger.debug('[LINEARIZE] message.assistant appended', {
        sessionId: active.sessionId,
        eventId: assistantMsgEvent.id,
        parentId: assistantMsgParentId,
      });

      // Also record tool_result blocks from tool result messages
      // TronAgent stores these as ToolResultMessage with role: 'toolResult'
      // Only get tool results from the CURRENT turn (after the last user message)
      // Note: toolResult messages come BETWEEN assistant messages, not after them
      let toolResultLastUserIndex = -1;
      for (let i = runResult.messages.length - 1; i >= 0; i--) {
        const msg = runResult.messages[i];
        if (msg && msg.role === 'user') {
          toolResultLastUserIndex = i;
          break;
        }
      }
      const currentTurnToolResults = runResult.messages
        .slice(toolResultLastUserIndex + 1)
        .filter((m: any) => m.role === 'toolResult') as any[];

      if (currentTurnToolResults.length > 0) {
        // Convert ToolResultMessage format to tool_result content blocks
        const toolResultBlocks = currentTurnToolResults.map(m => ({
          type: 'tool_result' as const,
          tool_use_id: m.toolCallId,
          content: typeof m.content === 'string' ? m.content :
                   Array.isArray(m.content) ? m.content.map((c: any) => c.text).join('\n') : '',
          is_error: m.isError === true,
        }));

        // Normalize with truncation for large content
        const normalizedToolResults = normalizeContentBlocks(toolResultBlocks);

        logger.debug('Storing tool results', {
          sessionId: active.sessionId,
          resultCount: normalizedToolResults.length,
          sampleContent: normalizedToolResults.slice(0, 3).map(r => ({
            type: r.type,
            toolUseId: (r.tool_use_id as string)?.slice(0, 20) + '...',
            hasContent: !!(r.content || r.text),
            contentLength: typeof r.content === 'string' ? r.content.length : 0,
          })),
        });

        // Store tool results as user message (linearized)
        // CRITICAL: Wait for any pending events before appending
        await active.appendPromiseChain;
        const toolResultParentId = active.pendingHeadEventId;
        const toolResultEvent = await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'message.user',
          payload: { content: normalizedToolResults },
          parentId: toolResultParentId,
        });
        active.pendingHeadEventId = toolResultEvent.id;
        logger.debug('[LINEARIZE] message.user (tool results) appended', {
          sessionId: active.sessionId,
          eventId: toolResultEvent.id,
          parentId: toolResultParentId,
        });
      }

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

      // Phase 3: Store error.agent event for agent-level errors (linearized)
      try {
        // CRITICAL: Wait for any pending events before appending
        await active.appendPromiseChain;
        const errorParentId = active.pendingHeadEventId ?? undefined;
        const errorEvent = await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'error.agent',
          payload: {
            error: error instanceof Error ? error.message : String(error),
            code: error instanceof Error ? error.name : undefined,
            recoverable: false,
          },
          parentId: errorParentId,
        });
        active.pendingHeadEventId = errorEvent.id;
        logger.debug('[LINEARIZE] error.agent appended', {
          sessionId: active.sessionId,
          eventId: errorEvent.id,
          parentId: errorParentId,
        });
      } catch (storeErr) {
        logger.error('Failed to store error.agent event', { storeErr, sessionId: options.sessionId });
      }

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

    // Actually abort the agent - triggers AbortController and interrupts execution
    active.agent.abort();

    active.isProcessing = false;
    active.lastActivity = new Date();
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

    // Get active session first to access pendingHeadEventId for linearization
    const active = this.activeSessions.get(sessionId);

    // P0 FIX: Prevent model switch during active agent processing
    // Modifying agent.model while agent.run() is in-flight causes inconsistent model usage
    if (active?.isProcessing) {
      throw new Error('Cannot switch model while agent is processing');
    }

    // Chain the model switch event append to the existing promise chain
    // This ensures it waits for pending events and captures the correct parentId
    // CRITICAL: Previous code had a race condition where concurrent switchModel() calls
    // would both capture the same pendingHeadEventId, creating spurious branches
    let modelSwitchEventId: EventId | null = null;
    let modelSwitchParentId: EventId | undefined;

    if (active) {
      const appendPromise = active.appendPromiseChain.then(async () => {
        // Capture parent ID INSIDE the chain callback - after previous events complete
        modelSwitchParentId = active.pendingHeadEventId ?? undefined;

        const event = await this.eventStore.append({
          sessionId: sessionId as SessionId,
          type: 'config.model_switch',
          payload: {
            previousModel,
            newModel: model,
          },
          parentId: modelSwitchParentId,
        });

        // Update in-memory head for next event
        active.pendingHeadEventId = event.id;
        modelSwitchEventId = event.id;
      });

      // Update the chain and wait for this specific event
      active.appendPromiseChain = appendPromise;
      await appendPromise;
    } else {
      // Session not active - direct append is safe (no concurrent events)
      const event = await this.eventStore.append({
        sessionId: sessionId as SessionId,
        type: 'config.model_switch',
        payload: {
          previousModel,
          newModel: model,
        },
      });
      modelSwitchEventId = event.id;
      modelSwitchParentId = event.parentId ?? undefined;
    }

    logger.debug('[LINEARIZE] config.model_switch appended', {
      sessionId,
      eventId: modelSwitchEventId,
      parentId: modelSwitchParentId,
    });

    // CRITICAL: Persist model change to session in database
    // Without this, the model reverts when session is reloaded
    await this.eventStore.updateSessionModel(sessionId as SessionId, model);
    logger.debug('[MODEL_SWITCH] Model persisted to database', { sessionId, model });

    // Update active session if exists
    if (active) {
      active.model = model;
      // CRITICAL: Use agent's switchModel() to preserve conversation history
      // Creating a new agent would lose all messages in this.messages
      active.agent.switchModel(model);
      logger.debug('[MODEL_SWITCH] Agent model switched (preserving messages)', { sessionId, model });
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

  // ===========================================================================
  // Linearized Event Appending
  // ===========================================================================

  /**
   * Append an event with linearized ordering per session.
   * Uses promise chaining to serialize event appends.
   *
   * CRITICAL: This solves the spurious branching bug where rapid events
   * A, B, C all capture the same parentId before any updates.
   *
   * The key insight: parentId is captured INSIDE the .then() callback,
   * which only runs AFTER the previous event's promise resolves.
   * This ensures each event correctly chains to the previous one.
   */
  private appendEventLinearized(
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>
  ): void {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      logger.error('Cannot append event: session not active', { sessionId, type });
      return;
    }

    // P0 FIX: Skip appends if prior append failed to prevent malformed event trees
    // If turn_start fails but turn_end succeeds, the tree becomes inconsistent
    if (active.lastAppendError) {
      logger.warn('Skipping append due to prior error', {
        sessionId,
        type,
        priorError: active.lastAppendError.message,
      });
      return;
    }

    if (!active.pendingHeadEventId) {
      logger.error('Cannot append event: no pending head event ID', { sessionId, type });
      return;
    }

    // Chain this append to the previous one
    // CRITICAL: parentId must be captured INSIDE .then() to get updated value
    active.appendPromiseChain = active.appendPromiseChain
      .then(async () => {
        // Check again inside chain - error may have occurred in previous chain link
        if (active.lastAppendError) {
          logger.warn('Skipping append in chain due to prior error', {
            sessionId,
            type,
            priorError: active.lastAppendError.message,
          });
          return;
        }

        // Capture parent ID HERE - after previous event has updated pendingHeadEventId
        const parentId = active.pendingHeadEventId;
        if (!parentId) {
          logger.error('Cannot append event: no pending head event ID in chain', { sessionId, type });
          return;
        }

        try {
          const event = await this.eventStore.append({
            sessionId,
            type,
            payload,
            parentId,
          });
          // Update in-memory head for the next event in the chain
          active.pendingHeadEventId = event.id;
        } catch (err) {
          logger.error(`Failed to store ${type} event`, { err, sessionId });
          // P0 FIX: Track error to prevent subsequent appends from creating orphaned events
          active.lastAppendError = err instanceof Error ? err : new Error(String(err));
        }
      });
  }

  /**
   * Wait for all pending event appends to complete for a session.
   * Useful for tests and ensuring DB state is consistent before queries.
   */
  async flushPendingEvents(sessionId: SessionId): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (active) {
      await active.appendPromiseChain;
    }
  }

  /**
   * Flush all active sessions' pending events.
   */
  async flushAllPendingEvents(): Promise<void> {
    const flushes = Array.from(this.activeSessions.values())
      .map(s => s.appendPromiseChain);
    await Promise.all(flushes);
  }

  private forwardAgentEvent(sessionId: SessionId, event: TronEvent): void {
    const timestamp = new Date().toISOString();
    const active = this.activeSessions.get(sessionId);

    switch (event.type) {
      case 'turn_start':
        // Update current turn for tool event tracking
        if (active) {
          active.currentTurn = event.turn;
          // NOTE: We do NOT reset accumulation here anymore!
          // We accumulate content across ALL turns within an agent run so that
          // when a client resumes into a running session, they get ALL content
          // from the current runAgent call (Turn 1, Turn 2, etc.), not just
          // the current turn. Accumulation is cleared at agent_start/agent_end.

          // Add a newline separator between turns (if there's existing content)
          // This ensures text from different turns doesn't run together
          if (event.turn > 1 && active.currentTurnAccumulatedText.length > 0) {
            active.currentTurnAccumulatedText += '\n';
          }
        }

        this.emit('agent_event', {
          type: 'agent.turn_start',
          sessionId,
          timestamp,
          data: { turn: event.turn },
        });

        // Store turn start event (linearized to prevent spurious branches)
        this.appendEventLinearized(sessionId, 'stream.turn_start', { turn: event.turn });
        break;

      case 'turn_end':
        // NOTE: We do NOT clear accumulation here anymore!
        // Content is kept so that if user resumes during a later turn,
        // they get ALL content from Turn 1, Turn 2, etc.
        // Accumulation is cleared at agent_start/agent_end instead.

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

        // Phase 4: Store turn end event with token usage (linearized)
        this.appendEventLinearized(sessionId, 'stream.turn_end', {
          turn: event.turn,
          tokenUsage: event.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
        });
        break;

      case 'message_update':
        // Accumulate text for resume support
        if (active && typeof event.content === 'string') {
          active.currentTurnAccumulatedText += event.content;

          // Track in content sequence for proper interleaving on interrupt
          // If the last item is a text item, append to it; otherwise add new text item
          const lastItem = active.currentTurnContentSequence[active.currentTurnContentSequence.length - 1];
          if (lastItem && lastItem.type === 'text') {
            lastItem.text += event.content;
          } else {
            active.currentTurnContentSequence.push({ type: 'text', text: event.content });
          }
        }

        this.emit('agent_event', {
          type: 'agent.text_delta',
          sessionId,
          timestamp,
          data: { delta: event.content },
        });
        break;

      case 'tool_execution_start':
        // Track tool call for resume support
        if (active) {
          active.currentTurnToolCalls.push({
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.arguments ?? {},
            status: 'running',
            startedAt: timestamp,
          });

          // Track in content sequence for proper interleaving on interrupt
          active.currentTurnContentSequence.push({
            type: 'tool_ref',
            toolCallId: event.toolCallId,
          });
        }

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

        // Phase 2: Store discrete tool.call event (linearized)
        this.appendEventLinearized(sessionId, 'tool.call', {
          toolCallId: event.toolCallId,
          name: event.toolName,
          arguments: event.arguments ?? {},
          turn: active?.currentTurn ?? 0,
        });
        break;

      case 'tool_execution_end': {
        const resultContent = typeof event.result === 'object' && event.result !== null
          ? (event.result as { content?: string }).content ?? JSON.stringify(event.result)
          : String(event.result ?? '');

        // Update tool call tracking for resume support
        if (active) {
          const toolCall = active.currentTurnToolCalls.find(
            tc => tc.toolCallId === event.toolCallId
          );
          if (toolCall) {
            toolCall.status = event.isError ? 'error' : 'completed';
            toolCall.result = resultContent;
            toolCall.isError = event.isError ?? false;
            toolCall.completedAt = timestamp;
          }
        }

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

        // Phase 2: Store discrete tool.result event (linearized)
        this.appendEventLinearized(sessionId, 'tool.result', {
          toolCallId: event.toolCallId,
          content: truncateString(resultContent, MAX_TOOL_RESULT_SIZE),
          isError: event.isError ?? false,
          duration: event.duration,
          truncated: resultContent.length > MAX_TOOL_RESULT_SIZE,
        });
        break;
      }

      case 'api_retry':
        // Phase 3: Store provider error event for API retries (linearized)
        this.appendEventLinearized(sessionId, 'error.provider', {
          provider: this.config.defaultProvider,
          error: event.errorMessage,
          code: event.errorCategory,
          retryable: true,
          retryAfter: event.delayMs,
        });
        break;

      case 'agent_start':
        // Clear accumulation at the start of a new agent run
        // This ensures fresh tracking for the new runAgent call
        if (active) {
          active.currentTurnAccumulatedText = '';
          active.currentTurnToolCalls = [];
          active.currentTurnContentSequence = [];
        }

        this.emit('agent_event', {
          type: 'agent.turn_start',
          sessionId,
          timestamp,
          data: {},
        });
        break;

      case 'agent_end':
        // Clear accumulation when agent run completes
        // Content is now persisted in EventStore, no need for catch-up tracking
        if (active) {
          active.currentTurnAccumulatedText = '';
          active.currentTurnToolCalls = [];
          active.currentTurnContentSequence = [];
        }

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
      inputTokens: row.totalInputTokens ?? 0,
      outputTokens: row.totalOutputTokens ?? 0,
      cost: row.totalCost ?? 0,
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

  private async cleanupInactiveSessions(): Promise<void> {
    const inactiveThreshold = 30 * 60 * 1000; // 30 minutes
    const now = Date.now();

    // P2 FIX: Create snapshot to avoid modification during iteration
    const entries = Array.from(this.activeSessions.entries());

    for (const [sessionId, active] of entries) {
      if (active.isProcessing) continue;

      const inactiveTime = now - active.lastActivity.getTime();
      if (inactiveTime > inactiveThreshold) {
        logger.info('Cleaning up inactive session', {
          sessionId,
          inactiveMinutes: Math.floor(inactiveTime / 60000),
        });

        // P2 FIX: Full cleanup including worktree release and session.end event
        try {
          await this.endSession(sessionId);
        } catch (err) {
          logger.error('Failed to end inactive session, removing from memory only', { sessionId, err });
          this.activeSessions.delete(sessionId);
        }
      }
    }
  }
}
