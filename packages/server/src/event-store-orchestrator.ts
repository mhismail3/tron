/**
 * @fileoverview EventStore-backed Session Orchestrator
 *
 * Manages multiple agent sessions using the EventStore for persistence.
 * This is the unified event-sourced architecture for session management.
 *
 * ## Streaming vs Persistence Model
 *
 * STREAMING EVENTS (ephemeral, WebSocket-only):
 * - `agent.text_delta` - Real-time text chunks for UI display
 * - `agent.tool_start/end` - Tool execution progress updates
 * - `agent.turn_start/end` - Turn lifecycle for UI spinners
 *
 * These events are emitted via WebSocket for real-time UI updates but are
 * NOT individually persisted to the EventStore. They accumulate in-memory
 * in TurnContentTracker for client catch-up (when resuming into running session).
 *
 * PERSISTED EVENTS (durable, EventStore):
 * - `message.assistant` - Consolidated assistant response at turn end
 * - `message.user` - User prompts and tool results
 * - `tool.call` / `tool.result` - Discrete tool events
 * - `stream.turn_start/end` - Turn boundaries for reconstruction
 * - `config.*` - Configuration changes (model, reasoning level, etc.)
 * - `skill.added` / `skill.removed` - Skill context changes
 * - `context.cleared` - Context clearing events
 * - `compact.boundary` / `compact.summary` - Compaction events
 *
 * This design is intentional:
 * 1. Streaming deltas are high-frequency, low-value for reconstruction
 * 2. The consolidated message.assistant is the source of truth
 * 3. Persisting deltas would bloat the event log without benefit
 * 4. Session state can be fully reconstructed from persisted events
 *
 * See TurnContentTracker for the in-memory accumulation logic.
 *
 * ## CRITICAL: Event Linearization
 *
 * All persisted events MUST maintain a linear chain via parentId for proper
 * session reconstruction. The ancestor chain (getAncestors) walks from head
 * to root - any event not in this chain will NOT be reconstructed.
 *
 * For active sessions, we maintain `pendingHeadEventId` in memory. This MUST
 * be updated after EVERY event append. The linearization system ensures:
 *
 * 1. Events are chained via appendPromiseChain (prevents race conditions)
 * 2. parentId is captured INSIDE the .then() callback (after previous event)
 * 3. pendingHeadEventId is updated after successful append
 *
 * The public `appendEvent()` method automatically handles linearization for
 * active sessions. Internal methods use `appendEventLinearized()` directly.
 *
 * WITHOUT LINEARIZATION: Out-of-band events (skill.removed, context.cleared,
 * model switches via RPC) would become orphaned branches because subsequent
 * agent messages would chain from the stale pendingHeadEventId.
 *
 * See orchestrator/event-linearizer.ts for the core implementation.
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
  BrowserTool,
  AskUserQuestionTool,
  OpenBrowserTool,
  AstGrepTool,
  loadServerAuth,
  getProviderAuthSync,
  detectProviderFromModel,
  KeywordSummarizer,
  SkillTracker,
  createSkillTracker,
  buildSkillContext,
  ContextLoader,
  RulesTracker,
  createRulesTracker,
  type SkillSource,
  type SkillAddMethod,
  type SkillMetadata,
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
  type ServerAuth,
  type EventType,
  type BrowserDelegate,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type Summarizer,
  type UserContent,
  type SkillTrackingEvent,
  type RulesLoadedPayload,
  type RulesTrackingEvent,
  isPlanModeEnteredEvent,
  isPlanModeExitedEvent,
  withLoggingContext,
} from '@tron/core';
import { BrowserService } from './browser/index.js';
import {
  normalizeContentBlocks,
  truncateString,
  MAX_TOOL_RESULT_SIZE,
} from './utils/content-normalizer.js';
import {
  appendEventLinearized as appendEventLinearizedImpl,
  appendEventLinearizedAsync as appendEventLinearizedAsyncImpl,
  flushPendingEvents as flushPendingEventsImpl,
  flushAllPendingEvents as flushAllPendingEventsImpl,
} from './orchestrator/event-linearizer.js';
import {
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './orchestrator/worktree-ops.js';
import { TurnContentTracker } from './orchestrator/turn-content-tracker.js';
import { createSessionContext } from './orchestrator/session-context.js';
import {
  type EventStoreOrchestratorConfig,
  type ActiveSession,
  type AgentRunOptions,
  type AgentEvent,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
  type WorktreeInfo,
} from './orchestrator/types.js';

// Re-export types for consumers
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
  WorktreeInfo,
};

const logger = createLogger('event-store-orchestrator');

// =============================================================================
// EventStore Orchestrator
// =============================================================================

export class EventStoreOrchestrator extends EventEmitter {
  private config: EventStoreOrchestratorConfig;
  private eventStore: EventStore;
  private worktreeCoordinator: WorktreeCoordinator;
  private browserService: BrowserService;
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

    // Initialize BrowserService
    this.browserService = new BrowserService({ headless: true });

    // Forward browser events
    this.browserService.on('browser.frame', (frame) => {
      this.emit('browser.frame', frame);
    });
    this.browserService.on('browser.closed', (sessionId) => {
      this.emit('browser.closed', sessionId);
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

    // Clean up all browser sessions
    if (this.browserService) {
      logger.debug('Cleaning up browser service');
      await this.browserService.cleanup();
    }

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

    // Load rules files for the session
    const rulesTracker = createRulesTracker();
    let rulesHeadEventId = result.rootEvent.id;
    try {
      const contextLoader = new ContextLoader({
        userHome: os.homedir(),
        projectRoot: workingDir.path,
      });
      const loadedContext = await contextLoader.load(workingDir.path);

      // Emit rules.loaded event if any rules files found
      if (loadedContext.files.length > 0) {
        const rulesPayload: RulesLoadedPayload = {
          files: loadedContext.files.map(f => ({
            path: f.path,
            relativePath: path.relative(workingDir.path, f.path) || f.path,
            level: f.level,
            depth: f.depth,
            sizeBytes: Buffer.byteLength(f.content, 'utf-8'),
          })),
          totalFiles: loadedContext.files.length,
          mergedTokens: this.estimateTokens(loadedContext.merged),
        };

        const rulesEvent = await this.eventStore.append({
          sessionId,
          type: 'rules.loaded' as EventType,
          payload: rulesPayload as unknown as Record<string, unknown>,
          parentId: result.rootEvent.id,
        });

        rulesTracker.setRules(
          rulesPayload.files,
          rulesPayload.mergedTokens,
          rulesEvent.id,
          loadedContext.merged
        );
        rulesHeadEventId = rulesEvent.id;

        // Inject rules content into agent for context building
        agent.setRulesContent(loadedContext.merged);

        logger.info('Rules loaded', {
          sessionId,
          fileCount: loadedContext.files.length,
          tokens: rulesPayload.mergedTokens,
        });
      }
    } catch (error) {
      // Log but don't fail session creation if rules loading fails
      logger.warn('Failed to load rules files', { sessionId, error });
    }

    // Create SessionContext for modular state management (Phase 6 migration)
    const sessionContext = createSessionContext({
      sessionId,
      eventStore: this.eventStore,
      initialHeadEventId: rulesHeadEventId,
      model,
      workingDirectory: workingDir.path,
      workingDir,
    });

    this.activeSessions.set(sessionId, {
      sessionId,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model,
      workingDir,
      currentTurn: 0,
      // Encapsulated content tracker for accumulated and per-turn tracking
      turnTracker: new TurnContentTracker(),
      // Initialize linearization tracking with rules event (or root) as head
      pendingHeadEventId: rulesHeadEventId,
      appendPromiseChain: Promise.resolve(),
      // Initialize current turn tracking for resume support (accumulated across all turns)
      currentTurnAccumulatedText: '',
      currentTurnToolCalls: [],
      currentTurnContentSequence: [],
      // Initialize per-turn tracking (cleared after each message.assistant)
      thisTurnContent: [],
      thisTurnToolCalls: new Map(),
      // Initialize parallel event ID tracking for context manager messages
      messageEventIds: [],
      // Initialize empty skill tracker (new sessions have no skills)
      skillTracker: createSkillTracker(),
      // Initialize rules tracker with loaded rules
      rulesTracker,
      // Initialize plan mode as inactive
      planMode: {
        isActive: false,
        blockedTools: [],
      },
      // Phase 6 migration: SessionContext for modular state management
      sessionContext,
    });

    this.emit('session_created', {
      sessionId,
      workingDirectory: workingDir.path,
      model,
      worktree: buildWorktreeInfo(workingDir),
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

    // Load full session state from event store first to get systemPrompt and reasoningLevel
    // This follows parent_id chain for forked sessions to include parent history
    const sessionState = await this.eventStore.getStateAtHead(session.id);

    // Create agent with restored system prompt (use resolved working directory path)
    const agent = await this.createAgentForSession(
      session.id,
      workingDir.path,
      session.latestModel,
      sessionState.systemPrompt // Restore system prompt from events
    );
    for (const msg of sessionState.messages) {
      // Convert event store messages to agent message format
      // Event store only returns 'user' and 'assistant' roles
      // Note: Content block types differ slightly between event store (Anthropic API format)
      // and agent types, but they are compatible at runtime for common cases (text, tool_use)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent.addMessage(msg as any);
    }

    // Restore reasoning level if persisted (for extended thinking models)
    const reasoningLevel = sessionState.reasoningLevel;
    if (reasoningLevel) {
      agent.setReasoningLevel(reasoningLevel);
      logger.info('Reasoning level restored from events', {
        sessionId,
        reasoningLevel,
      });
    }

    logger.info('Session history loaded', {
      sessionId,
      messageCount: sessionState.messages.length,
    });

    // Reconstruct skill tracker from event history
    // Use getAncestors to follow parent_id chain for forked sessions
    const events = session.headEventId
      ? await this.eventStore.getAncestors(session.headEventId)
      : [];
    const skillTracker = SkillTracker.fromEvents(events as SkillTrackingEvent[]);

    logger.info('Skill tracker reconstructed from events', {
      sessionId,
      addedSkillsCount: skillTracker.count,
    });

    // Reconstruct rules tracker from event history
    const rulesTracker = RulesTracker.fromEvents(events as RulesTrackingEvent[]);

    logger.info('Rules tracker reconstructed from events', {
      sessionId,
      rulesFileCount: rulesTracker.getTotalFiles(),
    });

    // Reconstruct plan mode state from event history
    const planMode = this.reconstructPlanModeFromEvents(events as TronSessionEvent[]);
    if (planMode.isActive) {
      logger.info('Plan mode reconstructed from events', {
        sessionId,
        skillName: planMode.skillName,
        blockedTools: planMode.blockedTools,
      });
    }

    // Re-load rules content from disk for the agent
    // (RulesTracker.fromEvents doesn't preserve merged content)
    if (rulesTracker.hasRules()) {
      try {
        const contextLoader = new ContextLoader({
          userHome: os.homedir(),
          projectRoot: workingDir.path,
        });
        const loadedContext = await contextLoader.load(workingDir.path);
        if (loadedContext.merged) {
          agent.setRulesContent(loadedContext.merged);
          logger.info('Rules content reloaded for resumed session', {
            sessionId,
            rulesContentLength: loadedContext.merged.length,
          });
        }
      } catch (error) {
        logger.warn('Failed to reload rules content for resumed session', { sessionId, error });
      }
    }

    // Create SessionContext for modular state management (Phase 6 migration)
    const sessionContext = createSessionContext({
      sessionId: session.id,
      eventStore: this.eventStore,
      initialHeadEventId: session.headEventId!,
      model: session.latestModel,
      workingDirectory: workingDir.path,
      workingDir,
      reasoningLevel,
    });
    // Restore state from events for SessionContext (plan mode, etc.)
    sessionContext.restoreFromEvents(events as TronSessionEvent[]);
    // Sync message event IDs for context audit
    sessionContext.setMessageEventIds(sessionState.messageEventIds);

    this.activeSessions.set(sessionId, {
      sessionId: session.id,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model: session.latestModel,
      workingDir,
      currentTurn: session.turnCount ?? 0,
      // Encapsulated content tracker for accumulated and per-turn tracking
      turnTracker: new TurnContentTracker(),
      // Initialize linearization tracking from session's current head
      pendingHeadEventId: session.headEventId ?? null,
      appendPromiseChain: Promise.resolve(),
      // Initialize current turn tracking for resume support (accumulated across all turns)
      currentTurnAccumulatedText: '',
      currentTurnToolCalls: [],
      currentTurnContentSequence: [],
      // Initialize per-turn tracking (cleared after each message.assistant)
      thisTurnContent: [],
      thisTurnToolCalls: new Map(),
      // Restore reasoning level from events
      reasoningLevel,
      // Restore parallel event ID tracking from persisted state
      messageEventIds: sessionState.messageEventIds,
      // Restore skill tracker from events
      skillTracker,
      // Restore rules tracker from events
      rulesTracker,
      // Restore plan mode state from events
      planMode,
      // Phase 6 migration: SessionContext for modular state management
      sessionContext,
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

    // Check if session exists in EventStore before attempting to append events
    // This handles the case where a stale session ID is sent (e.g., from iOS app
    // with a previous database) - we should succeed silently (idempotent delete)
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      logger.info('Session not found in EventStore, cleaning up local state only', { sessionId });

      // Clean up any local state even if session doesn't exist in DB
      if (active) {
        this.activeSessions.delete(sessionId);
      }

      // Release worktree if any (may not exist, that's fine)
      try {
        await this.worktreeCoordinator.release(sessionId as SessionId, {
          mergeTo: options?.mergeTo,
          mergeStrategy: options?.mergeStrategy,
          commitMessage: options?.commitMessage,
        });
      } catch (err) {
        // Worktree may not exist for this session, ignore
        logger.debug('No worktree to release for session', { sessionId, err });
      }

      // Clean up browser session if it exists
      if (this.browserService && this.browserService.hasSession(sessionId)) {
        logger.debug('Closing browser session during session end', { sessionId });
        await this.browserService.closeSession(sessionId);
      }

      this.emit('session_ended', { sessionId, reason: 'not_found' });
      return;
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

    // Clean up browser session if it exists
    if (this.browserService && this.browserService.hasSession(sessionId)) {
      logger.debug('Closing browser session during session end', { sessionId });
      await this.browserService.closeSession(sessionId);
    }

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

      // Fetch message previews for all sessions
      const previews = await this.eventStore.getSessionMessagePreviews(sessionIds);

      const sessions: SessionInfo[] = [];
      for (const a of active) {
        const session = sessionsMap.get(a.sessionId);
        if (session) {
          sessions.push(this.sessionRowToInfo(session, true, a.workingDir, previews.get(a.sessionId)));
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

    // Fetch message previews for all sessions
    const sessionIds = filtered.map(row => row.id);
    const previews = await this.eventStore.getSessionMessagePreviews(sessionIds);

    return filtered.map(row => {
      const active = this.activeSessions.get(row.id);
      return this.sessionRowToInfo(row, !!active, active?.workingDir, previews.get(row.id));
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
  // Fork
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
      worktree: buildWorktreeInfo(workingDir),
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
      worktree: buildWorktreeInfo(workingDir),
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

  /**
   * Append an event to a session.
   *
   * CRITICAL: For active sessions (with running agent), this automatically uses
   * linearized append to maintain proper event chain ordering. This prevents the
   * "orphaned branch" bug where out-of-band events (like skill.removed, context
   * clearing, model switches) get skipped because subsequent messages chain from
   * a stale parent.
   *
   * For inactive sessions, uses direct append since no race conditions are possible.
   */
  async appendEvent(options: AppendEventOptions): Promise<TronSessionEvent> {
    const active = this.activeSessions.get(options.sessionId);

    let event: TronSessionEvent;

    if (active) {
      // CRITICAL: For active sessions, use linearized append to:
      // 1. Wait for any pending appends to complete
      // 2. Chain from the correct parent (pendingHeadEventId)
      // 3. Update pendingHeadEventId so subsequent events chain correctly
      //
      // Without this, events appended via RPC (skill.removed, etc.) would
      // use the database head instead of the in-memory pending head, causing
      // subsequent agent messages to skip over the RPC-appended event.
      const linearizedEvent = await appendEventLinearizedAsyncImpl(
        this.eventStore,
        options.sessionId,
        active,
        options.type,
        options.payload
      );

      if (!linearizedEvent) {
        throw new Error(`Failed to append ${options.type} event (linearized append returned null)`);
      }
      event = linearizedEvent;
    } else {
      // For inactive sessions, direct append is safe (no concurrent events)
      event = await this.eventStore.append(options);
    }

    // Broadcast event to subscribers
    this.emit('event_new', {
      event,
      sessionId: options.sessionId,
    });

    return event;
  }

  /**
   * Delete a message from a session.
   *
   * This appends a message.deleted event to the event log. The original message
   * is preserved but will be filtered out during reconstruction (two-pass).
   *
   * CRITICAL: Uses linearized append via appendPromiseChain for active sessions
   * to prevent race conditions with concurrent agent events.
   */
  async deleteMessage(
    sessionId: string,
    targetEventId: string,
    reason?: 'user_request' | 'content_policy' | 'context_management'
  ): Promise<{ id: string; payload: unknown }> {
    const active = this.activeSessions.get(sessionId as SessionId);

    let deletionEvent: TronSessionEvent;

    if (active) {
      // CRITICAL: For active sessions, use linearized append to prevent race conditions
      // where concurrent events could capture stale parentId
      const appendPromise = active.appendPromiseChain.then(async () => {
        // Wait for any pending events, then validate and append deletion
        // Note: We use EventStore.deleteMessage which handles validation
        const event = await this.eventStore.deleteMessage(
          sessionId as SessionId,
          targetEventId as EventId,
          reason
        );
        // Update pending head INSIDE the chain callback
        active.pendingHeadEventId = event.id;
        return event;
      });

      // Update the chain and wait for this specific event
      active.appendPromiseChain = appendPromise.then(() => {});
      deletionEvent = await appendPromise;
    } else {
      // Session not active - direct append is safe (no concurrent events)
      deletionEvent = await this.eventStore.deleteMessage(
        sessionId as SessionId,
        targetEventId as EventId,
        reason
      );
    }

    // Broadcast the deletion event to subscribers
    this.emit('event_new', {
      event: deletionEvent,
      sessionId,
    });

    return {
      id: deletionEvent.id,
      payload: deletionEvent.payload,
    };
  }

  // ===========================================================================
  // Agent Operations
  // ===========================================================================

  async runAgent(options: AgentRunOptions): Promise<TurnResult[]> {
    const active = this.activeSessions.get(options.sessionId);
    if (!active) {
      throw new Error(`Session not active: ${options.sessionId}`);
    }

    // Phase 7 migration: Check processing state via SessionContext when available
    const isProcessing = active.sessionContext
      ? active.sessionContext.isProcessing()
      : active.isProcessing;
    if (isProcessing) {
      throw new Error('Session is already processing');
    }

    // Update both legacy and SessionContext (Phase 7 migration)
    active.isProcessing = true;
    active.lastActivity = new Date();
    if (active.sessionContext) {
      active.sessionContext.setProcessing(true);
    }

    // Wrap entire agent run with logging context for session correlation
    return withLoggingContext(
      { sessionId: options.sessionId },
      async () => {
    try {
      // CRITICAL: Wait for any pending stream events to complete before appending message events
      // This prevents race conditions where stream events (turn_start, etc.) capture wrong parentId
      await active.appendPromiseChain;

      // Track skills and load content BEFORE building user content
      // Skill context is now injected as a system block (not user message)
      const skillContext = await this.loadSkillContextForPrompt(active, options);

      // Set skill context on agent (will be injected into system prompt)
      if (skillContext) {
        const isRemovedInstruction = skillContext.includes('<removed-skills>');
        logger.info('[SKILL] Setting skill context on agent', {
          sessionId: active.sessionId,
          skillContextLength: skillContext.length,
          contextType: isRemovedInstruction ? 'removed-skills-instruction' : 'skill-content',
          preview: skillContext.substring(0, 150),
        });
        active.agent.setSkillContext(skillContext);
      } else {
        logger.info('[SKILL] No skill context to set (clearing)', {
          sessionId: active.sessionId,
        });
        active.agent.setSkillContext(undefined);
      }

      // Build user content from prompt and any attachments
      const userContent: UserContent[] = [];

      // Add text prompt (skill context is now in system prompt, not here)
      if (options.prompt) {
        userContent.push({ type: 'text', text: options.prompt });
      }

      // Add images from legacy images array
      if (options.images && options.images.length > 0) {
        for (const img of options.images) {
          if (img.mimeType.startsWith('image/')) {
            userContent.push({
              type: 'image',
              data: img.data,
              mimeType: img.mimeType,
            });
          }
        }
      }

      // Add images/documents from attachments array
      if (options.attachments && options.attachments.length > 0) {
        for (const att of options.attachments) {
          if (att.mimeType.startsWith('image/')) {
            userContent.push({
              type: 'image',
              data: att.data,
              mimeType: att.mimeType,
            });
          } else if (att.mimeType === 'application/pdf') {
            userContent.push({
              type: 'document',
              data: att.data,
              mimeType: att.mimeType,
              fileName: att.fileName,
            });
          } else if (att.mimeType.startsWith('text/') || att.mimeType === 'application/json') {
            // Text files: preserve as document blocks for display as attachments
            // The LLM will still be able to read them, but they'll render as thumbnails in the app
            userContent.push({
              type: 'document',
              data: att.data,
              mimeType: att.mimeType,
              fileName: att.fileName,
            });
          }
        }
      }

      logger.debug('Built user content', {
        sessionId: active.sessionId,
        contentBlocks: userContent.length,
        hasImages: userContent.some(c => c.type === 'image'),
        hasDocuments: userContent.some(c => c.type === 'document'),
        hasTextFiles: userContent.filter(c => c.type === 'text').length > 1,  // More than just the prompt
      });

      // Determine if we can use simple string format (backward compat) or need full content array
      const firstContent = userContent[0];
      const isSimpleTextOnly = userContent.length === 1 && firstContent?.type === 'text';
      const messageContent = isSimpleTextOnly ? options.prompt : userContent;

      // Record user message event (linearized to prevent spurious branches)
      // CRITICAL: Pass parentId from in-memory state, then update it after append
      const userMsgParentId = active.pendingHeadEventId ?? undefined;

      // Build payload with optional skills for chat history display
      const userMsgPayload: { content: unknown; skills?: { name: string; source: string }[] } = {
        content: messageContent,
      };
      if (options.skills && options.skills.length > 0) {
        userMsgPayload.skills = options.skills.map(s => ({ name: s.name, source: s.source }));
      }

      const userMsgEvent = await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.user',
        payload: userMsgPayload,
        parentId: userMsgParentId,
      });
      active.pendingHeadEventId = userMsgEvent.id;
      // Track eventId for context manager message (user message will be added to context by agent.run)
      active.messageEventIds.push(userMsgEvent.id);
      logger.debug('[LINEARIZE] message.user appended', {
        sessionId: active.sessionId,
        eventId: userMsgEvent.id,
        parentId: userMsgParentId,
      });

      // Set reasoning level if provided (for OpenAI Codex models)
      // Persist event only when level actually changes
      if (options.reasoningLevel && options.reasoningLevel !== active.reasoningLevel) {
        const previousLevel = active.reasoningLevel;
        active.agent.setReasoningLevel(options.reasoningLevel);
        active.reasoningLevel = options.reasoningLevel;

        // Persist reasoning level change as linearized event
        const reasoningParentId = active.pendingHeadEventId ?? undefined;
        const reasoningEvent = await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'config.reasoning_level',
          payload: {
            previousLevel,
            newLevel: options.reasoningLevel,
          },
          parentId: reasoningParentId,
        });
        active.pendingHeadEventId = reasoningEvent.id;
        logger.debug('[LINEARIZE] config.reasoning_level appended', {
          sessionId: active.sessionId,
          eventId: reasoningEvent.id,
          parentId: reasoningParentId,
          previousLevel,
          newLevel: options.reasoningLevel,
        });
      }

      // Transform content for LLM: convert text file documents to inline text
      // (Claude's document type only supports PDFs, not text files)
      const llmContent = this.transformContentForLLM(messageContent);

      // Run agent with transformed content
      const runResult = await active.agent.run(llmContent);
      // Update activity timestamp (Phase 7 migration: sync both)
      active.lastActivity = new Date();
      if (active.sessionContext) {
        active.sessionContext.touch();
      }

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
        // Use TurnContentTracker to build content blocks from accumulated state
        // This preserves exact interleaving order of text and tool calls
        const { assistantContent, toolResultContent } = active.turnTracker.buildInterruptedContent();

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
              hasAccumulatedContent: active.turnTracker.hasAccumulatedContent(),
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

        // Clear turn tracking state (both tracker and legacy fields for backward compatibility)
        active.turnTracker.onAgentEnd();
        active.currentTurnAccumulatedText = '';
        active.currentTurnToolCalls = [];
        active.currentTurnContentSequence = [];

        return [runResult] as unknown as TurnResult[];
      }

      // Wait for all linearized events (turn_end creates message.assistant and tool_results per-turn)
      // to complete before returning
      await active.appendPromiseChain;

      logger.debug('Agent run completed', {
        sessionId: active.sessionId,
        turns: runResult.turns,
        stoppedReason: runResult.stoppedReason,
      });

      // Emit turn completion event
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

      // Emit agent.complete AFTER appendPromiseChain completes
      // This ensures all linearized events (message.assistant, tool.call, tool.result)
      // are persisted to the database before iOS receives this and syncs
      this.emit('agent_event', {
        type: 'agent.complete',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          success: !runResult.error,
          error: runResult.error,
        },
      });

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

      // Emit agent.complete for error case (after appendPromiseChain has been awaited above)
      this.emit('agent_event', {
        type: 'agent.complete',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          success: false,
          error: error instanceof Error ? error.message : String(error),
        },
      });

      throw error;
    } finally {
      // Phase 7 migration: sync both legacy and SessionContext
      active.isProcessing = false;
      if (active.sessionContext) {
        active.sessionContext.setProcessing(false);
      }
    }
      }); // End withLoggingContext
  }

  async cancelAgent(sessionId: string): Promise<boolean> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return false;
    }

    // Phase 7 migration: Check processing state via SessionContext when available
    const isProcessing = active.sessionContext
      ? active.sessionContext.isProcessing()
      : active.isProcessing;
    if (!isProcessing) {
      return false;
    }

    // Actually abort the agent - triggers AbortController and interrupts execution
    active.agent.abort();

    // Phase 7 migration: sync both legacy and SessionContext
    active.isProcessing = false;
    active.lastActivity = new Date();
    if (active.sessionContext) {
      active.sessionContext.setProcessing(false);
    }
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

    const previousModel = session.latestModel;

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
    await this.eventStore.updateLatestModel(sessionId as SessionId, model);
    logger.debug('[MODEL_SWITCH] Model persisted to database', { sessionId, model });

    // Update active session if exists
    if (active) {
      // Get auth for the new model (handles Codex OAuth vs standard auth)
      const newAuth = await this.getAuthForProvider(model);
      const newProviderType = detectProviderFromModel(model);
      logger.debug('[MODEL_SWITCH] Auth loaded', { sessionId, authType: newAuth.type, providerType: newProviderType });

      active.model = model;
      // CRITICAL: Use agent's switchModel() to preserve conversation history
      // Pass the new auth to ensure correct credentials for the new provider
      active.agent.switchModel(model, undefined, newAuth);
      logger.debug('[MODEL_SWITCH] Agent model switched (preserving messages)', { sessionId, model, provider: newProviderType });
    }

    logger.info('Model switched', { sessionId, previousModel, newModel: model });

    return { previousModel, newModel: model };
  }

  // ===========================================================================
  // Context Management & Compaction
  // ===========================================================================

  /**
   * Get the current context snapshot for a session.
   * Returns token usage, limits, and threshold levels.
   * For inactive sessions, returns a default snapshot with zero usage.
   */
  getContextSnapshot(sessionId: string): ContextSnapshot {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      // Return default snapshot for inactive sessions
      // Use default model's context limit (200k for Claude Sonnet 4)
      return {
        currentTokens: 0,
        contextLimit: 200_000,
        usagePercent: 0,
        thresholdLevel: 'normal',
        breakdown: {
          systemPrompt: 0,
          tools: 0,
          rules: 0,
          messages: 0,
        },
      };
    }
    return active.agent.getContextManager().getSnapshot();
  }

  /**
   * Get detailed context snapshot with per-message token breakdown.
   * Returns empty messages array for inactive sessions.
   */
  getDetailedContextSnapshot(sessionId: string): DetailedContextSnapshot {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      // Return default snapshot for inactive sessions
      return {
        currentTokens: 0,
        contextLimit: 200_000,
        usagePercent: 0,
        thresholdLevel: 'normal',
        breakdown: {
          systemPrompt: 0,
          tools: 0,
          rules: 0,
          messages: 0,
        },
        messages: [],
        systemPromptContent: '',
        toolsContent: [],
      };
    }
    const snapshot = active.agent.getContextManager().getDetailedSnapshot();

    // Augment messages with eventIds from session tracking
    // The messageEventIds array parallels the context manager's messages array
    for (let i = 0; i < snapshot.messages.length; i++) {
      const eventId = active.messageEventIds[i];
      const message = snapshot.messages[i];
      if (eventId && message) {
        message.eventId = eventId;
      }
    }

    // Include rules data from the session's rules tracker
    if (active.rulesTracker.hasRules()) {
      const rulesFiles = active.rulesTracker.getRulesFiles();
      snapshot.rules = {
        files: rulesFiles.map(f => ({
          path: f.path,
          relativePath: f.relativePath,
          level: f.level,
          depth: f.depth,
        })),
        totalFiles: rulesFiles.length,
        tokens: active.rulesTracker.getMergedTokens(),
      };
    }

    // Include added skills from the session's skill tracker
    const addedSkills = active.skillTracker.getAddedSkills();
    const result = {
      ...snapshot,
      addedSkills: addedSkills.map(s => ({
        name: s.name,
        source: s.source,
        addedVia: s.addedVia,
        eventId: s.eventId,
      })),
    };

    return result;
  }

  /**
   * Check if a session needs compaction based on context threshold.
   * Returns false for inactive sessions (nothing to compact).
   */
  shouldCompact(sessionId: string): boolean {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return false; // Inactive sessions don't need compaction
    }
    return active.agent.getContextManager().shouldCompact();
  }

  /**
   * Preview compaction without executing it.
   * Returns estimated token reduction and generated summary.
   */
  async previewCompaction(sessionId: string): Promise<CompactionPreview> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const summarizer = this.getSummarizer();
    return active.agent.getContextManager().previewCompaction({ summarizer });
  }

  /**
   * Execute compaction on a session.
   * Stores compact.boundary and compact.summary events in EventStore.
   */
  async confirmCompaction(
    sessionId: string,
    opts?: { editedSummary?: string }
  ): Promise<CompactionResult> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();
    const summarizer = this.getSummarizer();

    const result = await cm.executeCompaction({
      summarizer,
      editedSummary: opts?.editedSummary,
    });

    // Clear skill tracker (skills don't survive compaction)
    active.skillTracker.clear();

    // Store compaction events in EventStore (linearized)
    await active.appendPromiseChain;

    // Store compact.boundary event
    const boundaryParentId = active.pendingHeadEventId ?? undefined;
    const boundaryEvent = await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'compact.boundary',
      payload: {
        originalTokens: tokensBefore,
        compactedTokens: result.tokensAfter,
        compressionRatio: result.compressionRatio,
      },
      parentId: boundaryParentId,
    });
    active.pendingHeadEventId = boundaryEvent.id;

    // Store compact.summary event
    const summaryParentId = active.pendingHeadEventId;
    const summaryEvent = await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'compact.summary',
      payload: {
        summary: result.summary,
        keyDecisions: result.extractedData?.keyDecisions?.map(d => d.decision),
        filesModified: result.extractedData?.filesModified,
      },
      parentId: summaryParentId,
    });
    active.pendingHeadEventId = summaryEvent.id;

    logger.info('Compaction completed', {
      sessionId,
      tokensBefore,
      tokensAfter: result.tokensAfter,
      compressionRatio: result.compressionRatio,
    });

    // Emit compaction_completed event
    this.emit('compaction_completed', {
      sessionId,
      tokensBefore,
      tokensAfter: result.tokensAfter,
      compressionRatio: result.compressionRatio,
      summary: result.summary,
    });

    return result;
  }

  /**
   * Pre-turn validation to check if a turn can proceed.
   * Returns whether compaction is needed and estimated token usage.
   * Inactive sessions can always accept turns (they'll be activated first).
   */
  canAcceptTurn(
    sessionId: string,
    opts: { estimatedResponseTokens: number }
  ): PreTurnValidation {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      // Inactive sessions can always accept turns - they'll be activated first
      return {
        canProceed: true,
        needsCompaction: false,
        wouldExceedLimit: false,
        currentTokens: 0,
        estimatedAfterTurn: opts.estimatedResponseTokens,
        contextLimit: 200_000,
      };
    }
    return active.agent.getContextManager().canAcceptTurn(opts);
  }

  /**
   * Clear all messages from context.
   * Unlike compaction, no summary is preserved - messages are just cleared.
   * Stores a context.cleared event in EventStore.
   */
  async clearContext(sessionId: string): Promise<{
    success: boolean;
    tokensBefore: number;
    tokensAfter: number;
  }> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();

    // Clear all messages from context manager
    cm.clearMessages();

    // Clear skill tracker (skills don't survive context clear)
    active.skillTracker.clear();

    const tokensAfter = cm.getCurrentTokens();

    // Store context.cleared event in EventStore (linearized)
    await active.appendPromiseChain;

    const parentId = active.pendingHeadEventId ?? undefined;
    const clearedEvent = await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'context.cleared',
      payload: {
        tokensBefore,
        tokensAfter,
        reason: 'manual',
      },
      parentId,
    });
    active.pendingHeadEventId = clearedEvent.id;

    logger.info('Context cleared', {
      sessionId,
      tokensBefore,
      tokensAfter,
      tokensFreed: tokensBefore - tokensAfter,
    });

    // Emit context_cleared event for WebSocket broadcast
    this.emit('context_cleared', {
      sessionId,
      tokensBefore,
      tokensAfter,
    });

    return {
      success: true,
      tokensBefore,
      tokensAfter,
    };
  }

  /**
   * Get a summarizer instance for compaction operations.
   */
  private getSummarizer(): Summarizer {
    // Use KeywordSummarizer for now - in production this would use LLM
    return new KeywordSummarizer();
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

    return buildWorktreeInfoWithStatus(active.workingDir);
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

    return commitWorkingDirectory(active.workingDir, message);
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

  /**
   * Load skill content and build context for a prompt.
   *
   * This method:
   * 1. Tracks skills (creates skill.added events for new skills)
   * 2. Collects skill names from explicitly selected skills (options.skills)
   * 3. Loads skill content via the skillLoader callback
   * 4. Builds and returns the skill context XML block
   *
   * Note: @mentions in prompt text are NOT extracted here. The iOS client handles
   * @mention detection and converts them to explicit skill chips before sending.
   * This ensures only skills the user explicitly selected (via chip) are included.
   *
   * @returns Skill context string to prepend to prompt, or empty string if no skills
   */
  private async loadSkillContextForPrompt(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<string> {
    // Get session skills already tracked (persistent across turns)
    const sessionSkills = active.skillTracker.getAddedSkills();

    // Log incoming skills for debugging
    logger.info('[SKILL] loadSkillContextForPrompt called', {
      sessionId: active.sessionId,
      skillsProvided: options.skills?.length ?? 0,
      skills: options.skills?.map(s => s.name) ?? [],
      sessionSkillCount: sessionSkills.length,
      sessionSkills: sessionSkills.map(s => s.name),
      hasSkillLoader: !!options.skillLoader,
    });

    // Collect skill names from:
    // 1. Session skills already in tracker (persistent across turns)
    // 2. Newly selected skills from options.skills
    const skillNames: Set<string> = new Set();

    // Add skills already in the session (from skillTracker)
    for (const addedSkill of sessionSkills) {
      skillNames.add(addedSkill.name);
    }

    // Add newly selected skills from options.skills
    if (options.skills && options.skills.length > 0) {
      for (const skill of options.skills) {
        skillNames.add(skill.name);
      }
    }

    // Track skills FIRST (creates events and updates tracker)
    // This must happen BEFORE checking removed skills, so that re-added skills
    // are properly removed from the removedSkillNames set
    if (skillNames.size > 0) {
      await this.trackSkillsForPrompt(active, options);
    }

    // NOW check for removed skills (after tracking, so re-added skills are excluded)
    const removedSkills = active.skillTracker.getRemovedSkillNames();
    let removedSkillsInstruction = '';
    if (removedSkills.length > 0) {
      const skillList = removedSkills.map(s => `@${s}`).join(', ');
      removedSkillsInstruction = `<removed-skills>
CRITICAL: The following skills have been REMOVED from this session: ${skillList}

You MUST completely stop applying these skill behaviors starting NOW. This includes:
- Do NOT use any special speaking styles, tones, or personas from these skills
- Do NOT follow any formatting rules from these skills
- Do NOT apply any behavioral modifications from these skills
- Respond in your normal, default manner

The user has explicitly removed these skills and expects you to respond WITHOUT them.
</removed-skills>`;
      logger.info('[SKILL] Including removed skills instruction', {
        sessionId: active.sessionId,
        removedSkills,
      });
    }

    // If no skills to add, return just the removed skills instruction (if any)
    if (skillNames.size === 0) {
      logger.info('[SKILL] No skills to load - returning removed skills instruction only', {
        hasRemovedInstruction: removedSkillsInstruction.length > 0,
      });
      return removedSkillsInstruction;
    }

    // If no skill loader provided, we can't load content
    if (!options.skillLoader) {
      logger.warn('[SKILL] Skills referenced but no skillLoader provided', {
        sessionId: active.sessionId,
        skillCount: skillNames.size,
        skillNames: Array.from(skillNames),
      });
      return '';
    }

    // Load skill content
    logger.info('[SKILL] Calling skillLoader for skills', {
      skillNames: Array.from(skillNames),
    });
    const loadedSkills = await options.skillLoader(Array.from(skillNames));

    logger.info('[SKILL] skillLoader returned', {
      requestedCount: skillNames.size,
      loadedCount: loadedSkills.length,
      loadedNames: loadedSkills.map(s => s.name),
    });

    if (loadedSkills.length === 0) {
      logger.warn('[SKILL] No skill content loaded', {
        sessionId: active.sessionId,
        requestedSkills: Array.from(skillNames),
      });
      return '';
    }

    // Build skill context using buildSkillContext
    // Convert LoadedSkillContent to SkillMetadata format for buildSkillContext
    const skillMetadata: SkillMetadata[] = loadedSkills.map(s => ({
      name: s.name,
      displayName: s.name,
      content: s.content,
      description: '',
      frontmatter: {},
      source: 'global' as const,
      path: '',
      skillMdPath: '',
      additionalFiles: [],
      lastModified: Date.now(),
    }));

    const skillContext = buildSkillContext(skillMetadata);

    logger.info('[SKILL] Built skill context successfully', {
      sessionId: active.sessionId,
      skillCount: loadedSkills.length,
      contextLength: skillContext.length,
      contextPreview: skillContext.substring(0, 200) + '...',
    });

    // Combine removed skills instruction with skill context
    if (removedSkillsInstruction) {
      return `${removedSkillsInstruction}\n\n${skillContext}`;
    }
    return skillContext;
  }

  /**
   * Track skills explicitly added with a prompt.
   *
   * Skills are tracked when explicitly selected via the skill sheet or
   * @mention detection in the client (passed in options.skills).
   *
   * Note: @mentions in prompt text are NOT extracted here. The iOS client handles
   * @mention detection and converts them to explicit skill chips before sending.
   *
   * For each skill not already tracked:
   * - Creates a skill.added event (persisted to EventStore)
   * - Adds the skill to the session's skillTracker
   *
   * This ensures skill tracking is:
   * - Persisted (events can be replayed for session resume/fork)
   * - Deferred until prompt send (not tracked while typing)
   * - Deduplicated (skills already in context are not re-added)
   */
  private async trackSkillsForPrompt(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> {
    // Collect skills to track from explicitly selected skills only
    // @mentions in prompt text are handled client-side (converted to chips)
    const skillsToTrack: Array<{
      name: string;
      source: SkillSource;
      addedVia: SkillAddMethod;
    }> = [];

    // Add explicitly selected skills from options.skills
    if (options.skills && options.skills.length > 0) {
      for (const skill of options.skills) {
        skillsToTrack.push({
          name: skill.name,
          source: skill.source,
          addedVia: 'explicit',
        });
      }
    }

    // Track each skill that's not already in the session's context
    for (const skill of skillsToTrack) {
      if (!active.skillTracker.hasSkill(skill.name)) {
        // Create skill.added event (linearized)
        const parentId = active.pendingHeadEventId ?? undefined;
        const skillEvent = await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'skill.added',
          payload: {
            skillName: skill.name,
            source: skill.source,
            addedVia: skill.addedVia,
          },
          parentId,
        });
        active.pendingHeadEventId = skillEvent.id;

        // Update in-memory tracker
        active.skillTracker.addSkill(
          skill.name,
          skill.source,
          skill.addedVia,
          skillEvent.id
        );

        logger.debug('[SKILL] skill.added event created', {
          sessionId: active.sessionId,
          skillName: skill.name,
          source: skill.source,
          addedVia: skill.addedVia,
          eventId: skillEvent.id,
        });
      }
    }
  }

  /**
   * Transform message content for LLM consumption.
   * Converts text file documents (text/*, application/json) to inline text content,
   * since Claude's document type only supports PDFs.
   * The original document blocks are preserved in the event store for iOS display.
   */
  private transformContentForLLM(content: string | UserContent[]): string | UserContent[] {
    // Simple string content - no transformation needed
    if (typeof content === 'string') {
      return content;
    }

    // Transform content blocks
    return content.map((block) => {
      // Only transform document blocks that are text files
      if (
        block.type === 'document' &&
        'mimeType' in block &&
        (block.mimeType?.startsWith('text/') || block.mimeType === 'application/json')
      ) {
        // Convert text file document to inline text content
        try {
          const textContent = Buffer.from(block.data as string, 'base64').toString('utf-8');
          const fileName = 'fileName' in block ? block.fileName : 'file';
          return {
            type: 'text' as const,
            text: `--- File: ${fileName} ---\n${textContent}\n--- End of file ---`,
          };
        } catch {
          // If decoding fails, return original block
          return block;
        }
      }
      // Keep other blocks as-is (images, PDFs, text)
      return block;
    });
  }

  private async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string
  ): Promise<TronAgent> {
    // Get auth for the model (handles Codex OAuth vs standard auth)
    const auth = await this.getAuthForProvider(model);
    const providerType = detectProviderFromModel(model);

    // Create BrowserDelegate for BrowserTool
    let browserDelegate: BrowserDelegate | undefined;
    if (this.browserService) {
      const service = this.browserService;
      browserDelegate = {
        execute: (sid, action, params) => service.execute(sid, action as any, params),
        ensureSession: async (sid) => {
          await service.createSession(sid);
          // Auto-start streaming so frames flow to iOS immediately
          // everyNthFrame: 6 means ~10 FPS (60Hz / 6 = 10 FPS)
          await service.startScreencast(sid, {
            format: 'jpeg',
            quality: 60,
            maxWidth: 1280,
            maxHeight: 800,
            everyNthFrame: 6,
          });
        },
        hasSession: (sid) => service.hasSession(sid),
      };
    }

    // AskUserQuestion uses async mode - no delegate needed
    // Questions are presented immediately, user answers as a new prompt
    const tools: TronTool[] = [
      new ReadTool({ workingDirectory }),
      new WriteTool({ workingDirectory }),
      new EditTool({ workingDirectory }),
      new BashTool({ workingDirectory }),
      new GrepTool({ workingDirectory }),
      new FindTool({ workingDirectory }),
      new LsTool({ workingDirectory }),
      new BrowserTool({ workingDirectory, delegate: browserDelegate }),
      new AskUserQuestionTool({ workingDirectory }),
      new OpenBrowserTool({ workingDirectory }),
      new AstGrepTool({ workingDirectory }),
    ];

    // System prompt is now handled by ContextManager based on provider type
    // Only pass custom prompt if explicitly provided - otherwise ContextManager
    // will use TRON_CORE_PROMPT with provider-specific adaptations
    const prompt = systemPrompt; // May be undefined - that's fine

    logger.info('Creating agent with tools', {
      sessionId,
      workingDirectory,
      toolCount: tools.length,
      authType: auth.type,
      isOAuth: auth.type === 'oauth',
      providerType,
    });

    const agentConfig: AgentConfig = {
      provider: {
        model,
        auth, // Use OAuth from Codex tokens or auth.json
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

  /**
   * Load Codex OAuth tokens from unified auth storage
   */
  private loadCodexTokens(): { accessToken: string; refreshToken: string; expiresAt: number } | null {
    try {
      const codexAuth = getProviderAuthSync('openai-codex');
      if (codexAuth?.oauth) {
        return {
          accessToken: codexAuth.oauth.accessToken,
          refreshToken: codexAuth.oauth.refreshToken,
          expiresAt: codexAuth.oauth.expiresAt,
        };
      }
    } catch (error) {
      logger.warn('Failed to load Codex tokens', { error });
    }
    return null;
  }

  /**
   * Get authentication credentials for a given model.
   * Handles Codex OAuth tokens separately from standard auth.
   * Refreshes cached auth if OAuth tokens are expired.
   */
  private async getAuthForProvider(model: string): Promise<ServerAuth> {
    const providerType = detectProviderFromModel(model);

    if (providerType === 'openai-codex') {
      // Load Codex-specific OAuth tokens
      const codexTokens = this.loadCodexTokens();
      if (!codexTokens) {
        throw new Error('OpenAI Codex not authenticated. Sign in via the iOS app or use a different model.');
      }
      return {
        type: 'oauth',
        accessToken: codexTokens.accessToken,
        refreshToken: codexTokens.refreshToken,
        expiresAt: codexTokens.expiresAt,
      };
    }

    // Use cached auth from ~/.tron/auth.json (supports Claude Max OAuth)
    // Refresh cache if needed (OAuth tokens expire)
    if (!this.cachedAuth || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
      this.cachedAuth = await loadServerAuth();
    }

    if (!this.cachedAuth) {
      throw new Error('No authentication configured. Run `tron login` to authenticate.');
    }

    return this.cachedAuth;
  }

  // ===========================================================================
  // Linearized Event Appending
  // ===========================================================================

  /**
   * Append an event with linearized ordering per session.
   * Delegates to event-linearizer module for the core logic.
   */
  private appendEventLinearized(
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      logger.error('Cannot append event: session not active', { sessionId, type });
      return;
    }
    appendEventLinearizedImpl(this.eventStore, sessionId, active, type, payload, onCreated);
  }

  /**
   * Wait for all pending event appends to complete for a session.
   * Useful for tests and ensuring DB state is consistent before queries.
   */
  async flushPendingEvents(sessionId: SessionId): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (active) {
      await flushPendingEventsImpl(active);
    }
  }

  /**
   * Flush all active sessions' pending events.
   */
  async flushAllPendingEvents(): Promise<void> {
    await flushAllPendingEventsImpl(this.activeSessions.values());
  }

  private forwardAgentEvent(sessionId: SessionId, event: TronEvent): void {
    const timestamp = new Date().toISOString();
    const active = this.activeSessions.get(sessionId);

    switch (event.type) {
      case 'turn_start':
        // Update current turn for tool event tracking
        if (active) {
          active.currentTurn = event.turn;
          // Record turn start time for latency calculation
          active.currentTurnStartTime = Date.now();

          // Use TurnContentTracker for turn lifecycle
          active.turnTracker.onTurnStart(event.turn);

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          active.thisTurnContent = [];
          active.thisTurnToolCalls = new Map();
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
        // NOTE: We do NOT clear accumulated content here anymore!
        // Accumulated content is kept so that if user resumes during a later turn,
        // they get ALL content from Turn 1, Turn 2, etc.
        // Accumulation is cleared at agent_start/agent_end instead.

        // Store per-turn token usage
        // This is the ACTUAL per-turn value from the LLM, not cumulative
        // Includes cache token breakdown for accurate cost calculation
        if (active && event.tokenUsage) {
          active.lastTurnTokenUsage = {
            inputTokens: event.tokenUsage.inputTokens,
            outputTokens: event.tokenUsage.outputTokens,
            cacheReadTokens: event.tokenUsage.cacheReadTokens,
            cacheCreationTokens: event.tokenUsage.cacheCreationTokens,
          };
        }

        // CREATE MESSAGE.ASSISTANT FOR THIS TURN - THIS IS WHAT GETS PERSISTED
        // Consolidates all streaming deltas (text_delta) into a single durable event.
        // This is the source of truth for session reconstruction.
        // Each turn gets its own message.assistant event with per-turn token data.
        if (active && active.thisTurnContent.length > 0) {
          // Build content blocks from this turn's content
          const contentBlocks: any[] = [];
          for (const item of active.thisTurnContent) {
            if (item.type === 'text' && item.text) {
              contentBlocks.push({ type: 'text', text: item.text });
            } else if (item.type === 'tool_ref') {
              const tc = active.thisTurnToolCalls.get(item.toolCallId);
              if (tc) {
                contentBlocks.push({
                  type: 'tool_use',
                  id: tc.toolCallId,
                  name: tc.toolName,
                  input: tc.arguments,
                });
              }
            }
          }

          // Calculate latency for this turn
          const turnLatency = active.currentTurnStartTime
            ? Date.now() - active.currentTurnStartTime
            : event.duration ?? 0;

          // Detect if content has thinking blocks
          const hasThinking = contentBlocks.some((b: any) => b.type === 'thinking');

          // Normalize content blocks
          const normalizedContent = normalizeContentBlocks(contentBlocks);

          // Create message.assistant event for this turn
          if (normalizedContent.length > 0) {
            this.appendEventLinearized(sessionId, 'message.assistant', {
              content: normalizedContent,
              tokenUsage: active.lastTurnTokenUsage,
              turn: event.turn,
              model: active.model,
              stopReason: 'end_turn',
              latency: turnLatency,
              hasThinking,
            }, (evt) => {
              // Track eventId for context manager message
              // Re-fetch active session since callback is async
              const currentActive = this.activeSessions.get(sessionId);
              if (currentActive) {
                currentActive.messageEventIds.push(evt.id);
              }
            });

            logger.debug('Created message.assistant for turn', {
              sessionId,
              turn: event.turn,
              contentBlocks: normalizedContent.length,
              tokenUsage: active.lastTurnTokenUsage,
              latency: turnLatency,
            });
          }

          // NOTE: Tool results are NOT persisted as message.user at turn end.
          // Reasons:
          // 1. In-memory context manager handles tool results during the turn
          // 2. For tools like AskUserQuestion with stopTurn, storing tool_result
          //    would create consecutive user messages (invalid for API)
          // 3. The assistant's response already incorporates tool results
          // 4. Tool results are stored as tool.result events for streaming/display

          // Clear THIS TURN's content (but keep accumulated content for catch-up)
          active.thisTurnContent = [];
          active.thisTurnToolCalls = new Map();
        }

        this.emit('agent_event', {
          type: 'agent.turn_end',
          sessionId,
          timestamp,
          data: {
            turn: event.turn,
            duration: event.duration,
            tokenUsage: event.tokenUsage,
            cost: event.cost,
          },
        });

        // Phase 4: Store turn end event with token usage and cost (linearized)
        this.appendEventLinearized(sessionId, 'stream.turn_end', {
          turn: event.turn,
          tokenUsage: event.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
          cost: event.cost,
        });
        break;

      case 'message_update':
        // STREAMING ONLY - NOT PERSISTED TO EVENT STORE
        // Text deltas are accumulated in TurnContentTracker for:
        // 1. Real-time WebSocket emission (agent.text_delta below)
        // 2. Client catch-up when resuming into running session
        // 3. Building consolidated message.assistant at turn_end (which IS persisted)
        //
        // Individual deltas are ephemeral by design - high frequency, low reconstruction value.
        // The source of truth is the message.assistant event created at turn_end.
        if (active && typeof event.content === 'string') {
          // Use TurnContentTracker for text delta (updates both accumulated and per-turn)
          active.turnTracker.addTextDelta(event.content);

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          active.currentTurnAccumulatedText += event.content;
          const lastItem = active.currentTurnContentSequence[active.currentTurnContentSequence.length - 1];
          if (lastItem && lastItem.type === 'text') {
            lastItem.text += event.content;
          } else {
            active.currentTurnContentSequence.push({ type: 'text', text: event.content });
          }
          const lastThisTurnItem = active.thisTurnContent[active.thisTurnContent.length - 1];
          if (lastThisTurnItem && lastThisTurnItem.type === 'text') {
            lastThisTurnItem.text += event.content;
          } else {
            active.thisTurnContent.push({ type: 'text', text: event.content });
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
        // Track tool call for resume support (across ALL turns)
        if (active) {
          // Use TurnContentTracker for tool start (updates both accumulated and per-turn)
          active.turnTracker.startToolCall(
            event.toolCallId,
            event.toolName,
            event.arguments ?? {},
            timestamp
          );

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          const toolCallData = {
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.arguments ?? {},
            status: 'running' as const,
            startedAt: timestamp,
          };
          active.currentTurnToolCalls.push(toolCallData);
          active.currentTurnContentSequence.push({
            type: 'tool_ref',
            toolCallId: event.toolCallId,
          });
          active.thisTurnToolCalls.set(event.toolCallId, { ...toolCallData });
          active.thisTurnContent.push({
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
        // Extract text content from TronToolResult
        // content can be string OR array of { type: 'text', text } | { type: 'image', ... }
        const resultContent = (() => {
          if (typeof event.result !== 'object' || event.result === null) {
            return String(event.result ?? '');
          }
          const result = event.result as { content?: string | Array<{ type: string; text?: string }> };
          if (typeof result.content === 'string') {
            return result.content;
          }
          if (Array.isArray(result.content)) {
            // Extract text from content blocks, join with newlines
            return result.content
              .filter((block): block is { type: 'text'; text: string } =>
                block.type === 'text' && typeof block.text === 'string')
              .map(block => block.text)
              .join('\n');
          }
          // Fallback: stringify the whole result
          return JSON.stringify(event.result);
        })();

        // Update tool call tracking for resume support (across ALL turns)
        if (active) {
          // Use TurnContentTracker for tool end (updates both accumulated and per-turn)
          active.turnTracker.endToolCall(
            event.toolCallId,
            resultContent,
            event.isError ?? false,
            timestamp
          );

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          const toolCall = active.currentTurnToolCalls.find(
            tc => tc.toolCallId === event.toolCallId
          );
          if (toolCall) {
            toolCall.status = event.isError ? 'error' : 'completed';
            toolCall.result = resultContent;
            toolCall.isError = event.isError ?? false;
            toolCall.completedAt = timestamp;
          }
          const thisTurnToolCall = active.thisTurnToolCalls.get(event.toolCallId);
          if (thisTurnToolCall) {
            thisTurnToolCall.status = event.isError ? 'error' : 'completed';
            thisTurnToolCall.result = resultContent;
            thisTurnToolCall.isError = event.isError ?? false;
            thisTurnToolCall.completedAt = timestamp;
          }
        }

        // Extract details from tool result (e.g., full screenshot data for iOS)
        const resultDetails = typeof event.result === 'object' && event.result !== null
          ? (event.result as { details?: unknown }).details
          : undefined;

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
            // Include details for clients that need full binary data (e.g., iOS screenshots)
            // This is NOT persisted to event store to avoid bloating storage
            details: resultDetails,
          },
        });

        // Phase 2: Store discrete tool.result event (linearized)
        this.appendEventLinearized(sessionId, 'tool.result', {
          toolCallId: event.toolCallId,
          content: truncateString(resultContent, MAX_TOOL_RESULT_SIZE),
          isError: event.isError ?? false,
          duration: event.duration,
          truncated: resultContent.length > MAX_TOOL_RESULT_SIZE,
        }, (evt) => {
          // Track eventId for context manager message (tool result)
          // Re-fetch active session since callback is async
          const currentActive = this.activeSessions.get(sessionId);
          if (currentActive) {
            currentActive.messageEventIds.push(evt.id);
          }
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
          // Use TurnContentTracker for agent lifecycle
          active.turnTracker.onAgentStart();

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          active.currentTurnAccumulatedText = '';
          active.currentTurnToolCalls = [];
          active.currentTurnContentSequence = [];
          active.lastTurnTokenUsage = undefined;
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
          // Use TurnContentTracker for agent lifecycle
          active.turnTracker.onAgentEnd();

          // LEGACY: Keep old fields synchronized for backward compatibility during transition
          active.currentTurnAccumulatedText = '';
          active.currentTurnToolCalls = [];
          active.currentTurnContentSequence = [];
        }

        // NOTE: agent.complete is now emitted in runAgent() AFTER appendPromiseChain completes
        // This ensures all linearized events (message.assistant, tool.call, tool.result)
        // are persisted before iOS syncs on receiving agent.complete
        // See runAgent() line ~908 for the emit
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

      case 'compaction_complete':
        this.emit('agent_event', {
          type: 'agent.compaction',
          sessionId,
          timestamp,
          data: {
            tokensBefore: event.tokensBefore,
            tokensAfter: event.tokensAfter,
            compressionRatio: event.compressionRatio,
            reason: event.reason || 'auto',
          },
        });
        break;
    }
  }

  /**
   * Estimate token count for a string.
   * Uses 4 chars per token as a rough estimate (consistent with context.compactor).
   */
  private estimateTokens(text: string): number {
    return Math.ceil(text.length / 4);
  }

  private sessionRowToInfo(
    row: any,
    isActive: boolean,
    workingDir?: WorkingDirectory,
    preview?: { lastUserPrompt?: string; lastAssistantResponse?: string }
  ): SessionInfo {
    const cacheReadTokens = row.totalCacheReadTokens ?? 0;
    const cacheCreationTokens = row.totalCacheCreationTokens ?? 0;
    if (cacheReadTokens > 0 || cacheCreationTokens > 0) {
      logger.debug(`[CACHE] sessionRowToInfo: session=${row.id}, cacheRead=${cacheReadTokens}, cacheCreation=${cacheCreationTokens}`);
    }
    return {
      sessionId: row.id,
      workingDirectory: workingDir?.path ?? row.workingDirectory,
      // Use latestModel from DB, but expose as 'model' for backward compatibility
      model: row.latestModel,
      messageCount: row.messageCount ?? 0,
      eventCount: row.eventCount ?? 0,
      inputTokens: row.totalInputTokens ?? 0,
      outputTokens: row.totalOutputTokens ?? 0,
      lastTurnInputTokens: row.lastTurnInputTokens ?? 0,
      cacheReadTokens,
      cacheCreationTokens,
      cost: row.totalCost ?? 0,
      createdAt: row.createdAt,
      lastActivity: row.lastActivityAt,
      isActive,
      worktree: workingDir ? buildWorktreeInfo(workingDir) : undefined,
      parentSessionId: row.parentSessionId ?? undefined,
      lastUserPrompt: preview?.lastUserPrompt,
      lastAssistantResponse: preview?.lastAssistantResponse,
    };
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
      // Phase 7 migration: Check via SessionContext when available
      const isProcessing = active.sessionContext
        ? active.sessionContext.isProcessing()
        : active.isProcessing;
      if (isProcessing) continue;

      const lastActivity = active.sessionContext
        ? active.sessionContext.getLastActivity()
        : active.lastActivity;
      const inactiveTime = now - lastActivity.getTime();
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

  // ===========================================================================
  // Browser Service Methods (for RPC adapter)
  // ===========================================================================

  /**
   * Start browser frame streaming for a session
   */
  async startBrowserStream(sessionId: string): Promise<{ success: boolean; error?: string }> {
    // Create browser session if it doesn't exist
    if (!this.browserService.hasSession(sessionId)) {
      const createResult = await this.browserService.createSession(sessionId);
      if (!createResult.success) {
        return { success: false, error: createResult.error || 'Failed to create browser session' };
      }
    }

    // Start screencast
    const result = await this.browserService.startScreencast(sessionId);
    if (!result.success) {
      return { success: false, error: result.error || 'Failed to start screencast' };
    }

    return { success: true };
  }

  /**
   * Stop browser frame streaming for a session
   */
  async stopBrowserStream(sessionId: string): Promise<{ success: boolean; error?: string }> {
    if (!this.browserService.hasSession(sessionId)) {
      return { success: true }; // Already not streaming
    }

    // Stop screencast
    const result = await this.browserService.stopScreencast(sessionId);
    if (!result.success) {
      return { success: false, error: result.error || 'Failed to stop screencast' };
    }

    return { success: true };
  }

  /**
   * Get browser status for a session
   */
  async getBrowserStatus(sessionId: string): Promise<{ hasBrowser: boolean; isStreaming: boolean; currentUrl?: string }> {
    if (!this.browserService.hasSession(sessionId)) {
      return { hasBrowser: false, isStreaming: false };
    }

    const session = this.browserService.getSession(sessionId);
    return {
      hasBrowser: true,
      isStreaming: session?.isStreaming ?? false,
      currentUrl: session?.page?.url(),
    };
  }

  // ===========================================================================
  // Plan Mode Methods
  // ===========================================================================

  /**
   * Check if a session is in plan mode
   * Phase 6 migration: Uses SessionContext when available, falls back to legacy field
   */
  isInPlanMode(sessionId: string): boolean {
    const active = this.activeSessions.get(sessionId);
    if (!active) return false;
    // Use SessionContext if available (Phase 6 migration)
    if (active.sessionContext) {
      return active.sessionContext.isInPlanMode();
    }
    // Fallback to legacy field
    return active.planMode.isActive;
  }

  /**
   * Get the list of blocked tools for a session
   * Phase 6 migration: Uses SessionContext when available, falls back to legacy field
   */
  getBlockedTools(sessionId: string): string[] {
    const active = this.activeSessions.get(sessionId);
    if (!active) return [];
    // Use SessionContext if available (Phase 6 migration)
    if (active.sessionContext) {
      return active.sessionContext.getBlockedTools();
    }
    // Fallback to legacy field
    return active.planMode.blockedTools;
  }

  /**
   * Check if a specific tool is blocked for a session
   * Phase 6 migration: Uses SessionContext when available, falls back to legacy field
   */
  isToolBlocked(sessionId: string, toolName: string): boolean {
    const active = this.activeSessions.get(sessionId);
    if (!active) return false;
    // Use SessionContext if available (Phase 6 migration)
    if (active.sessionContext) {
      return active.sessionContext.isToolBlocked(toolName);
    }
    // Fallback to legacy field
    if (!active.planMode.isActive) return false;
    return active.planMode.blockedTools.includes(toolName);
  }

  /**
   * Get a descriptive error message for blocked tools
   */
  getPlanModeBlockedToolMessage(toolName: string): string {
    return `Tool "${toolName}" is blocked during plan mode. ` +
      `The session is in read-only exploration mode until the plan is approved. ` +
      `Use AskUserQuestion to present your plan and get user approval.`;
  }

  /**
   * Enter plan mode for a session
   * @param sessionId - Session ID
   * @param options - Plan mode options (skill name and blocked tools)
   * Phase 6 migration: Updates both legacy fields and SessionContext
   */
  async enterPlanMode(
    sessionId: string,
    options: { skillName: string; blockedTools: string[] }
  ): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Check via SessionContext if available, otherwise legacy field
    const isActive = active.sessionContext
      ? active.sessionContext.isInPlanMode()
      : active.planMode.isActive;
    if (isActive) {
      throw new Error(`Session ${sessionId} is already in plan mode`);
    }

    // Append plan.mode_entered event
    const parentId = active.pendingHeadEventId ?? undefined;
    const event = await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'plan.mode_entered' as EventType,
      payload: {
        skillName: options.skillName,
        blockedTools: options.blockedTools,
      },
      parentId,
    });

    active.pendingHeadEventId = event.id;

    // Update in-memory state (legacy field)
    active.planMode = {
      isActive: true,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
    };

    // Phase 6 migration: Also update SessionContext
    if (active.sessionContext) {
      active.sessionContext.enterPlanMode(options.skillName, options.blockedTools);
    }

    logger.info('Plan mode entered', {
      sessionId,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
      eventId: event.id,
    });

    this.emit('plan.mode_entered', {
      sessionId,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
    });
  }

  /**
   * Exit plan mode for a session
   * @param sessionId - Session ID
   * @param options - Exit options (reason and optional plan path)
   * Phase 6 migration: Updates both legacy fields and SessionContext
   */
  async exitPlanMode(
    sessionId: string,
    options: { reason: 'approved' | 'cancelled' | 'timeout'; planPath?: string }
  ): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Check via SessionContext if available, otherwise legacy field
    const isActive = active.sessionContext
      ? active.sessionContext.isInPlanMode()
      : active.planMode.isActive;
    if (!isActive) {
      throw new Error(`Session ${sessionId} is not in plan mode`);
    }

    // Build payload (only include planPath if present)
    const payload: Record<string, unknown> = { reason: options.reason };
    if (options.planPath) {
      payload.planPath = options.planPath;
    }

    // Append plan.mode_exited event
    const parentId = active.pendingHeadEventId ?? undefined;
    const event = await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'plan.mode_exited' as EventType,
      payload,
      parentId,
    });

    active.pendingHeadEventId = event.id;

    // Update in-memory state (legacy field)
    active.planMode = {
      isActive: false,
      blockedTools: [],
    };

    // Phase 6 migration: Also update SessionContext
    if (active.sessionContext) {
      active.sessionContext.exitPlanMode();
    }

    logger.info('Plan mode exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
      eventId: event.id,
    });

    this.emit('plan.mode_exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
    });
  }

  /**
   * Reconstruct plan mode state from event history
   * @private
   */
  private reconstructPlanModeFromEvents(
    events: TronSessionEvent[]
  ): { isActive: boolean; skillName?: string; blockedTools: string[] } {
    let planModeActive = false;
    let skillName: string | undefined;
    let blockedTools: string[] = [];

    for (const event of events) {
      if (isPlanModeEnteredEvent(event)) {
        planModeActive = true;
        skillName = event.payload.skillName;
        blockedTools = event.payload.blockedTools;
      } else if (isPlanModeExitedEvent(event)) {
        planModeActive = false;
        skillName = undefined;
        blockedTools = [];
      }
    }

    return { isActive: planModeActive, skillName, blockedTools };
  }
}
