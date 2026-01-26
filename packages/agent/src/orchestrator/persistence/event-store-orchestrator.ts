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
 * Each active session has a SessionContext that encapsulates:
 * - EventPersister: Handles promise chaining to prevent race conditions
 * - TurnManager: Tracks turn lifecycle and content accumulation
 * - PlanModeHandler: Manages plan mode state
 *
 * The EventPersister ensures linearization by:
 * 1. Chaining events via an internal promise chain (prevents race conditions)
 * 2. Capturing parentId inside the chain (after previous event completes)
 * 3. Updating the pending head after successful append
 *
 * The public `appendEvent()` method automatically handles linearization for
 * active sessions via SessionContext. Internal methods use `appendEventLinearized()`.
 *
 * WITHOUT LINEARIZATION: Out-of-band events (skill.removed, context.cleared,
 * model switches via RPC) would become orphaned branches because subsequent
 * agent messages would chain from a stale head.
 */
import { EventEmitter } from 'events';
import * as crypto from 'crypto';
import * as path from 'path';
import * as os from 'os';
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '../../logging/logger.js';
import { TronAgent } from '../../agent/tron-agent.js';
import type { TurnResult } from '../../agent/types.js';
import { EventStore, type AppendEventOptions, type SearchOptions } from '../../events/event-store.js';
import {
  type SessionEvent as TronSessionEvent,
  type SessionState as EventSessionState,
  type Message as EventMessage,
  type EventId,
  type SessionId,
  type WorkspaceId,
  type EventType,
} from '../../events/types.js';
import {
  WorktreeCoordinator,
  createWorktreeCoordinator,
} from '../../session/worktree-coordinator.js';
import { loadServerAuth } from '../../auth/oauth.js';
import { SubAgentTracker, type SubagentResult } from '../../tools/subagent/subagent-tracker.js';
import type { TronEvent } from '../../types/events.js';
import type {
  ContextSnapshot,
  DetailedContextSnapshot,
  PreTurnValidation,
  CompactionPreview,
  CompactionResult,
} from '../../context/context-manager.js';
import type { SpawnSubagentParams } from '../../tools/subagent/spawn-subagent.js';
import type { SpawnTmuxAgentParams } from '../../tools/subagent/spawn-tmux-agent.js';
import type {
  SubagentQueryType,
  SubagentStatusInfo,
  SubagentEventInfo,
  SubagentLogInfo,
} from '../../tools/subagent/query-subagent.js';
import type { TodoItem, BackloggedTask } from '../../todos/types.js';
import { BrowserService } from '../../external/browser/index.js';
import { SessionError } from '../../utils/errors.js';
import {
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from '../operations/worktree-ops.js';
import {
  SubagentOperations,
  createSubagentOperations,
} from '../operations/subagent-ops.js';
import {
  AgentEventHandler,
  createAgentEventHandler,
} from '../turn/agent-event-handler.js';
import {
  SkillLoader,
  createSkillLoader,
} from '../operations/skill-loader.js';
import {
  SessionManager,
  createSessionManager,
} from '../session/session-manager.js';
import {
  ContextOps,
  createContextOps,
} from '../operations/context-ops.js';
import {
  AgentFactory,
  createAgentFactory,
} from '../agent-factory.js';
import {
  AuthProvider,
  createAuthProvider,
} from '../session/auth-provider.js';
import {
  APNSService,
  createAPNSService,
} from '../../external/apns/index.js';
import {
  type EventStoreOrchestratorConfig,
  type ActiveSession,
  type AgentRunOptions,
  type AgentEvent,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
  type WorktreeInfo,
} from '../types.js';
import {
  PlanModeController,
  createPlanModeController,
} from '../controllers/plan-mode-controller.js';
import {
  TodoController,
  createTodoController,
} from '../controllers/todo-controller.js';
import {
  NotificationController,
  createNotificationController,
} from '../controllers/notification-controller.js';
import {
  AgentRunner,
  createAgentRunner,
} from '../agent-runner.js';
import {
  ModelController,
  createModelController,
} from '../controllers/model-controller.js';

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
  private eventStore: EventStore;
  private worktreeCoordinator: WorktreeCoordinator;
  private browserService: BrowserService;
  private subagentOps: SubagentOperations;
  private agentEventHandler: AgentEventHandler;
  private skillLoader: SkillLoader;
  private sessionManager: SessionManager;
  private contextOps: ContextOps;
  private agentFactory: AgentFactory;
  private authProvider: AuthProvider;
  private apnsService: APNSService | null = null;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;
  private initialized = false;

  // Controllers extracted for better separation of concerns
  private planModeController: PlanModeController;
  private todoController: TodoController;
  private notificationController!: NotificationController;

  // Extracted agent execution coordinator
  private agentRunner: AgentRunner;

  // Model switching coordinator
  private modelController: ModelController;

  constructor(config: EventStoreOrchestratorConfig) {
    super();

    // Use injected EventStore (for testing) or create new one
    if (config.eventStore) {
      this.eventStore = config.eventStore;
    } else {
      const eventStoreDbPath = config.eventStoreDbPath ??
        path.join(os.homedir(), '.tron', 'db', 'prod.db');
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

    // Initialize SubagentOperations (delegated module)
    this.subagentOps = createSubagentOperations({
      eventStore: this.eventStore,
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      createSession: (options) => this.createSession(options),
      runAgent: (options) => this.runAgent(options),
      appendEventLinearized: (sessionId, type, payload) =>
        this.appendEventLinearized(sessionId, type, payload),
      emit: (event, data) => this.emit(event, data),
    });

    // Initialize AgentEventHandler (delegated module)
    this.agentEventHandler = createAgentEventHandler({
      defaultProvider: config.defaultProvider,
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      appendEventLinearized: (sessionId, type, payload, onCreated) =>
        this.appendEventLinearized(sessionId, type, payload, onCreated),
      emit: (event, data) => this.emit(event, data),
    });

    // Initialize SkillLoader (delegated module)
    this.skillLoader = createSkillLoader();

    // Initialize SessionManager (delegated module)
    this.sessionManager = createSessionManager({
      eventStore: this.eventStore,
      worktreeCoordinator: this.worktreeCoordinator,
      defaultModel: config.defaultModel,
      defaultProvider: config.defaultProvider,
      maxConcurrentSessions: config.maxConcurrentSessions,
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      setActiveSession: (sessionId: string, session: ActiveSession) =>
        this.activeSessions.set(sessionId, session),
      deleteActiveSession: (sessionId: string) => this.activeSessions.delete(sessionId),
      getActiveSessionCount: () => this.activeSessions.size,
      getAllActiveSessions: () => this.activeSessions.entries(),
      createAgentForSession: (sessionId, workingDirectory, model, systemPrompt, isSubagent) =>
        this.createAgentForSession(sessionId, workingDirectory, model, systemPrompt, isSubagent),
      emit: (event, data) => this.emit(event, data),
      estimateTokens: (text) => this.estimateTokens(text),
      hasBrowserSession: (sessionId) => this.browserService?.hasSession(sessionId) ?? false,
      closeBrowserSession: async (sessionId) => {
        await this.browserService?.closeSession(sessionId);
      },
    });

    // Initialize ContextOps (delegated module)
    this.contextOps = createContextOps({
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      emit: (event, data) => this.emit(event, data),
    });

    // Initialize AuthProvider (delegated module)
    this.authProvider = createAuthProvider();

    // Initialize APNS Service for push notifications (optional)
    this.apnsService = createAPNSService();
    if (this.apnsService) {
      logger.info('APNS service initialized for push notifications');
    }

    // Initialize AgentFactory (delegated module)
    this.agentFactory = createAgentFactory({
      getAuthForProvider: (model) => this.authProvider.getAuthForProvider(model),
      spawnSubsession: (parentId, params, toolCallId) => this.spawnSubsession(parentId, params, toolCallId),
      querySubagent: (sessionId, queryType, limit) => this.querySubagent(sessionId, queryType, limit),
      waitForSubagents: (sessionIds, mode, timeout) => this.waitForSubagents(sessionIds, mode, timeout),
      forwardAgentEvent: (sessionId, event) => this.forwardAgentEvent(sessionId, event),
      getSubagentTrackerForSession: (sessionId) => this.activeSessions.get(sessionId)?.subagentTracker,
      onTodosUpdated: async (sessionId, todos) => this.todoController.handleTodosUpdated(sessionId, todos),
      generateTodoId: () => `todo_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`,
      onNotify: this.apnsService ? async (sessionId, notification, toolCallId) => {
        return this.notificationController.sendNotification(sessionId, notification, toolCallId);
      } : undefined,
      browserService: this.browserService ? {
        execute: (sid, action, params) => this.browserService.execute(sid, action, params),
        createSession: async (sid) => { await this.browserService.createSession(sid); },
        startScreencast: async (sid, options) => { await this.browserService.startScreencast(sid, options); },
        hasSession: (sid) => this.browserService.hasSession(sid),
      } : undefined,
    });

    // Forward browser events
    this.browserService.on('browser.frame', (frame) => {
      this.emit('browser.frame', frame);
    });
    this.browserService.on('browser.closed', (sessionId) => {
      this.emit('browser.closed', sessionId);
    });

    // Initialize PlanModeController (delegated module)
    this.planModeController = createPlanModeController({
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      emit: (event, data) => this.emit(event, data),
    });

    // Initialize TodoController (delegated module)
    this.todoController = createTodoController({
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      eventStore: this.eventStore,
      emit: (event, data) => this.emit(event, data),
    });

    // Initialize NotificationController (delegated module)
    this.notificationController = createNotificationController({
      apnsService: this.apnsService,
      eventStore: this.eventStore,
    });

    // Initialize AgentRunner (extracted agent execution coordinator)
    this.agentRunner = createAgentRunner({
      skillLoader: this.skillLoader,
      emit: (event, data) => this.emit(event, data),
      enterPlanMode: (sessionId, opts) => this.enterPlanMode(sessionId, opts),
      isInPlanMode: (sessionId) => this.isInPlanMode(sessionId),
      buildSubagentResultsContext: (active) => this.buildSubagentResultsContext(active),
    });

    // Initialize ModelController (extracted model switching coordinator)
    this.modelController = createModelController({
      eventStore: this.eventStore,
      authProvider: this.authProvider,
      getActiveSession: (sessionId) => this.activeSessions.get(sessionId),
    });
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  async initialize(): Promise<void> {
    if (this.initialized) return;

    // Load auth from ~/.tron/auth.json (supports Claude Max OAuth)
    // IMPORTANT: Does NOT check ANTHROPIC_API_KEY env var - that would override OAuth
    const cachedAuth = await loadServerAuth();
    this.authProvider.setCachedAuth(cachedAuth);
    if (!cachedAuth) {
      logger.warn('No authentication configured - run tron login to authenticate');
    } else {
      logger.info('Authentication loaded', {
        type: cachedAuth.type,
        isOAuth: cachedAuth.type === 'oauth',
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
        // Wrap in SessionError for structured logging but don't re-throw during shutdown
        const sessionError = new SessionError('Failed to end session during shutdown', {
          sessionId,
          operation: 'close',
          cause: error instanceof Error ? error : undefined,
        });
        logger.error('Failed to end session during shutdown', sessionError.toStructuredLog());
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
  // Session Management (delegated to SessionManager)
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<SessionInfo> {
    return this.sessionManager.createSession(options);
  }

  async resumeSession(sessionId: string): Promise<SessionInfo> {
    return this.sessionManager.resumeSession(sessionId);
  }

  async endSession(sessionId: string, options?: {
    mergeTo?: string;
    mergeStrategy?: 'merge' | 'rebase' | 'squash';
    commitMessage?: string;
  }): Promise<void> {
    return this.sessionManager.endSession(sessionId, options);
  }

  async getSession(sessionId: string): Promise<SessionInfo | null> {
    return this.sessionManager.getSession(sessionId);
  }

  async listSessions(options: {
    workingDirectory?: string;
    limit?: number;
    activeOnly?: boolean;
  }): Promise<SessionInfo[]> {
    return this.sessionManager.listSessions(options);
  }

  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.activeSessions.get(sessionId);
  }

  async wasSessionInterrupted(sessionId: string): Promise<boolean> {
    return this.sessionManager.wasSessionInterrupted(sessionId);
  }

  // ===========================================================================
  // Fork (delegated to SessionManager)
  // ===========================================================================

  async forkSession(sessionId: string, fromEventId?: string): Promise<ForkResult> {
    return this.sessionManager.forkSession(sessionId, fromEventId);
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
      // CRITICAL: For active sessions, use SessionContext for linearized append:
      // 1. Wait for any pending appends to complete
      // 2. Chain from the correct parent
      // 3. Update pending head so subsequent events chain correctly
      //
      // Without this, events appended via RPC (skill.removed, etc.) would
      // use the database head instead of the in-memory pending head, causing
      // subsequent agent messages to skip over the RPC-appended event.
      const linearizedEvent = await active.sessionContext!.appendEvent(
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
   * CRITICAL: Uses SessionContext's linearized append for active sessions
   * to prevent race conditions with concurrent agent events.
   */
  async deleteMessage(
    sessionId: string,
    targetEventId: string,
    reason?: 'user_request' | 'content_policy' | 'context_management'
  ): Promise<{ id: string; payload: unknown }> {
    const active = this.activeSessions.get(sessionId as SessionId);

    let deletionEvent: TronSessionEvent;

    if (active?.sessionContext) {
      // CRITICAL: For active sessions, use SessionContext's linearization chain
      // deleteMessage handles validation internally, we just need proper chaining
      deletionEvent = await active.sessionContext.runInChain(async () => {
        return this.eventStore.deleteMessage(
          sessionId as SessionId,
          targetEventId as EventId,
          reason
        );
      });
    } else {
      // Session not active - direct call is safe (no concurrent events)
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
    let active = this.activeSessions.get(options.sessionId);

    // Auto-resume session if not active (handles app reopen, server restart, etc.)
    if (!active) {
      logger.info('[AGENT] Auto-resuming inactive session', { sessionId: options.sessionId });
      try {
        await this.resumeSession(options.sessionId);
        active = this.activeSessions.get(options.sessionId);
      } catch (err) {
        // Session doesn't exist or can't be resumed
        throw new Error(`Session not found: ${options.sessionId}`);
      }
      if (!active) {
        throw new Error(`Failed to resume session: ${options.sessionId}`);
      }
    }

    // Check processing state
    if (active.sessionContext.isProcessing()) {
      throw new Error('Session is already processing');
    }

    // Update processing state
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(true);

    try {
      // Delegate to AgentRunner for all execution logic
      // AgentRunner handles: context injection, content building, agent execution,
      // interrupt handling, completion handling, error handling, and event emission
      return await this.agentRunner.run(active, options) as TurnResult[];
    } finally {
      // Clear processing state
      active.sessionContext.setProcessing(false);
    }
  }

  async cancelAgent(sessionId: string): Promise<boolean> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return false;
    }

    if (!active.sessionContext.isProcessing()) {
      return false;
    }

    // Actually abort the agent - triggers AbortController and interrupts execution
    active.agent.abort();

    // Clear processing state
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(false);
    logger.info('Agent cancelled', { sessionId });
    return true;
  }

  // ===========================================================================
  // Model Switching (delegated to ModelController)
  // ===========================================================================

  async switchModel(sessionId: string, model: string): Promise<{ previousModel: string; newModel: string }> {
    return this.modelController.switchModel(sessionId, model);
  }

  // ===========================================================================
  // Context Management & Compaction (delegated to ContextOps)
  // ===========================================================================

  getContextSnapshot(sessionId: string): ContextSnapshot {
    return this.contextOps.getContextSnapshot(sessionId);
  }

  getDetailedContextSnapshot(sessionId: string): DetailedContextSnapshot {
    return this.contextOps.getDetailedContextSnapshot(sessionId);
  }

  shouldCompact(sessionId: string): boolean {
    return this.contextOps.shouldCompact(sessionId);
  }

  async previewCompaction(sessionId: string): Promise<CompactionPreview> {
    return this.contextOps.previewCompaction(sessionId);
  }

  async confirmCompaction(
    sessionId: string,
    opts?: { editedSummary?: string; reason?: string }
  ): Promise<CompactionResult> {
    return this.contextOps.confirmCompaction(sessionId, opts);
  }

  canAcceptTurn(
    sessionId: string,
    opts: { estimatedResponseTokens: number }
  ): PreTurnValidation {
    return this.contextOps.canAcceptTurn(sessionId, opts);
  }

  async clearContext(sessionId: string): Promise<{
    success: boolean;
    tokensBefore: number;
    tokensAfter: number;
  }> {
    return this.contextOps.clearContext(sessionId);
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
    // Cast string IDs to branded types for EventStore
    const searchOptions: SearchOptions | undefined = options ? {
      workspaceId: options.workspaceId as WorkspaceId | undefined,
      sessionId: options.sessionId as SessionId | undefined,
      types: options.types as EventType[] | undefined,
      limit: options.limit,
    } : undefined;
    return this.eventStore.search(query, searchOptions);
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
    // Use sessionContext.isProcessing() as the authoritative source of truth
    const processingSessions = Array.from(this.activeSessions.values())
      .filter(a => a.sessionContext.isProcessing()).length;

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
   * Load skill context for a prompt. Delegates to SkillLoader.
   * @internal Exposed for testing - prefer using runAgent which handles this automatically.
   */
  // @ts-expect-error - Exposed for testing via (orchestrator as any).loadSkillContextForPrompt
  private async loadSkillContextForPrompt(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<string> {
    return this.skillLoader.loadSkillContextForPrompt(
      {
        sessionId: active.sessionId,
        skillTracker: active.skillTracker,
        sessionContext: active.sessionContext!,
      },
      options
    );
  }

  /**
   * Track skills for a prompt. Delegates to SkillLoader.
   * @internal Exposed for testing - prefer using runAgent which handles this automatically.
   */
  // @ts-expect-error - Exposed for testing via (orchestrator as any).trackSkillsForPrompt
  private async trackSkillsForPrompt(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> {
    return this.skillLoader.trackSkillsForPrompt(
      {
        sessionId: active.sessionId,
        skillTracker: active.skillTracker,
        sessionContext: active.sessionContext!,
      },
      options
    );
  }

  // ===========================================================================
  // Agent Factory (delegated to AgentFactory)
  // ===========================================================================

  private async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string,
    isSubagent?: boolean
  ): Promise<TronAgent> {
    return this.agentFactory.createAgentForSession(sessionId, workingDirectory, model, systemPrompt, isSubagent);
  }

  // ===========================================================================
  // Linearized Event Appending
  // ===========================================================================

  /**
   * Append an event with linearized ordering per session (fire-and-forget).
   * Uses SessionContext's EventPersister for linearization.
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
    // Use SessionContext for linearized append
    active.sessionContext!.appendEventFireAndForget(type, payload, onCreated);
  }

  /**
   * Wait for all pending event appends to complete for a session.
   * Useful for tests and ensuring DB state is consistent before queries.
   */
  async flushPendingEvents(sessionId: SessionId): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (active?.sessionContext) {
      await active.sessionContext.flushEvents();
    }
  }

  /**
   * Flush all active sessions' pending events.
   */
  async flushAllPendingEvents(): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const active of this.activeSessions.values()) {
      if (active.sessionContext) {
        promises.push(active.sessionContext.flushEvents());
      }
    }
    await Promise.all(promises);
  }

  // ===========================================================================
  // Sub-Agent Operations (delegated to SubagentOperations module)
  // ===========================================================================

  /**
   * Spawn an in-process sub-agent session.
   * The sub-agent runs asynchronously and shares the event store.
   */
  async spawnSubsession(
    parentSessionId: string,
    params: SpawnSubagentParams,
    toolCallId?: string
  ): Promise<{ sessionId: string; success: boolean; error?: string }> {
    return this.subagentOps.spawnSubsession(parentSessionId, params, toolCallId);
  }

  /**
   * Spawn an out-of-process sub-agent in a tmux session.
   * The sub-agent runs independently with its own process.
   */
  async spawnTmuxAgent(
    parentSessionId: string,
    params: SpawnTmuxAgentParams
  ): Promise<{ sessionId: string; tmuxSessionName: string; success: boolean; error?: string }> {
    return this.subagentOps.spawnTmuxAgent(parentSessionId, params);
  }

  /**
   * Query a sub-agent's status, events, logs, or output.
   */
  async querySubagent(
    sessionId: string,
    queryType: SubagentQueryType,
    limit?: number
  ): Promise<{
    success: boolean;
    status?: SubagentStatusInfo;
    events?: SubagentEventInfo[];
    logs?: SubagentLogInfo[];
    output?: string;
    error?: string;
  }> {
    return this.subagentOps.querySubagent(sessionId, queryType, limit);
  }

  /**
   * Wait for sub-agent(s) to complete.
   * Uses the SubagentTracker's promise-based waiting mechanism.
   *
   * @param sessionIds - Array of session IDs to wait for
   * @param mode - 'all' to wait for all, 'any' to return on first completion
   * @param timeout - Maximum time to wait in milliseconds
   */
  async waitForSubagents(
    sessionIds: string[],
    mode: 'all' | 'any',
    timeout: number
  ): Promise<{
    success: boolean;
    results?: SubagentResult[];
    error?: string;
    timedOut?: boolean;
  }> {
    // Find which parent session has trackers for these sub-agents
    // by checking all active sessions' subagent trackers
    // Note: This logic stays in orchestrator because it needs to iterate activeSessions
    let parentTracker: SubAgentTracker | undefined;

    for (const active of this.activeSessions.values()) {
      // Check if this session tracks any of the requested sub-agents
      for (const sessionId of sessionIds) {
        if (active.subagentTracker.has(sessionId as SessionId)) {
          parentTracker = active.subagentTracker;
          break;
        }
      }
      if (parentTracker) break;
    }

    if (!parentTracker) {
      return {
        success: false,
        error: `No tracker found for session(s): ${sessionIds.join(', ')}`,
      };
    }

    try {
      let results: SubagentResult[];

      if (mode === 'any') {
        const result = await parentTracker.waitForAny(
          sessionIds as SessionId[],
          timeout
        );
        results = [result];
      } else {
        results = await parentTracker.waitForAll(
          sessionIds as SessionId[],
          timeout
        );
      }

      return { success: true, results };
    } catch (error) {
      const err = error as Error;
      const isTimeout = err.message.includes('Timeout');

      logger.error('Error waiting for subagents', {
        sessionIds,
        mode,
        error: err.message,
        timedOut: isTimeout,
      });

      return {
        success: false,
        error: err.message,
        timedOut: isTimeout,
      };
    }
  }

  /**
   * Build context string for pending sub-agent results.
   * Delegated to SubagentOperations module.
   */
  private buildSubagentResultsContext(active: ActiveSession): string | undefined {
    return this.subagentOps.buildSubagentResultsContext(active);
  }

  // ===========================================================================
  // Agent Event Handling (delegated to AgentEventHandler module)
  // ===========================================================================

  /**
   * Forward an agent event for processing.
   * Delegated to AgentEventHandler module.
   */
  private forwardAgentEvent(sessionId: SessionId, event: TronEvent): void {
    this.agentEventHandler.forwardEvent(sessionId, event);
  }

  /**
   * Estimate token count for a string.
   * Uses 4 chars per token as a rough estimate (consistent with context.compactor).
   */
  private estimateTokens(text: string): number {
    return Math.ceil(text.length / 4);
  }

  private startCleanupTimer(): void {
    this.cleanupTimer = setInterval(() => {
      this.sessionManager.cleanupInactiveSessions();
    }, 5 * 60 * 1000);
  }

  private stopCleanupTimer(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
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
    let currentUrl: string | undefined;
    try {
      currentUrl = session?.manager?.isLaunched() ? session.manager.getPage().url() : undefined;
    } catch {
      // Browser not ready
    }
    return {
      hasBrowser: true,
      isStreaming: session?.isStreaming ?? false,
      currentUrl,
    };
  }

  // ===========================================================================
  // Plan Mode Methods
  // ===========================================================================

  /**
   * Check if a session is in plan mode
   */
  // ===========================================================================
  // Plan Mode Operations (delegated to PlanModeController)
  // ===========================================================================

  isInPlanMode(sessionId: string): boolean {
    return this.planModeController.isInPlanMode(sessionId);
  }

  getBlockedTools(sessionId: string): string[] {
    return this.planModeController.getBlockedTools(sessionId);
  }

  isToolBlocked(sessionId: string, toolName: string): boolean {
    return this.planModeController.isToolBlocked(sessionId, toolName);
  }

  getPlanModeBlockedToolMessage(toolName: string): string {
    return this.planModeController.getBlockedToolMessage(toolName);
  }

  async enterPlanMode(
    sessionId: string,
    options: { skillName: string; blockedTools: string[] }
  ): Promise<void> {
    return this.planModeController.enterPlanMode(sessionId, options);
  }

  async exitPlanMode(
    sessionId: string,
    options: { reason: 'approved' | 'cancelled' | 'timeout'; planPath?: string }
  ): Promise<void> {
    return this.planModeController.exitPlanMode(sessionId, options);
  }

  // ===========================================================================
  // Todo Operations (delegated to TodoController)
  // ===========================================================================

  getTodos(sessionId: string): TodoItem[] {
    return this.todoController.getTodos(sessionId);
  }

  getTodoSummary(sessionId: string): string {
    return this.todoController.getTodoSummary(sessionId);
  }

  // ===========================================================================
  // Backlog Operations (delegated to TodoController)
  // ===========================================================================

  getBacklog(workspaceId: string, options?: { includeRestored?: boolean; limit?: number }): BackloggedTask[] {
    return this.todoController.getBacklog(workspaceId, options);
  }

  getBacklogCount(workspaceId: string): number {
    return this.todoController.getBacklogCount(workspaceId);
  }

  async restoreFromBacklog(sessionId: string, taskIds: string[]): Promise<TodoItem[]> {
    return this.todoController.restoreFromBacklog(sessionId, taskIds);
  }

  async backlogIncompleteTodos(
    sessionId: string,
    workspaceId: string,
    reason: 'session_clear' | 'context_compact' | 'session_end'
  ): Promise<number> {
    return this.todoController.backlogIncompleteTodos(sessionId, workspaceId, reason);
  }
}
