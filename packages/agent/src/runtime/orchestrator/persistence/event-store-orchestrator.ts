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
import { createLogger } from '@infrastructure/logging/index.js';
import { TronAgent } from '../../agent/tron-agent.js';
import { EventStore } from '@infrastructure/events/event-store.js';
import {
  type SessionEvent as TronSessionEvent,
  type SessionId,
  type EventType,
} from '@infrastructure/events/types.js';
import {
  WorktreeCoordinator,
  createWorktreeCoordinator,
} from '@platform/session/worktree-coordinator.js';
import { loadServerAuth } from '@infrastructure/auth/oauth.js';
import { getServiceAuthSync } from '@infrastructure/auth/unified.js';
import { SubAgentTracker, type SubagentResult } from '@capabilities/tools/subagent/subagent-tracker.js';
import type { TronEvent } from '@core/types/events.js';
import { BrowserService } from '@platform/external/browser/index.js';
import { SessionError } from '@core/utils/errors.js';
import {
  SubagentOperations,
  createSubagentOperations,
} from '../operations/subagent-ops/index.js';
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
import { EmbeddingService, buildEmbeddingText } from '@infrastructure/embeddings/index.js';
import type { VectorRepository } from '@infrastructure/events/sqlite/repositories/vector.repo.js';
import type { MemoryLedgerPayload } from '@infrastructure/events/types/memory.js';
import { getSettings } from '@infrastructure/settings/loader.js';
import {
  AuthProvider,
  createAuthProvider,
} from '../session/auth-provider.js';
import {
  APNSService,
  createAPNSService,
} from '@platform/external/apns/index.js';
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
import {
  EventController,
  createEventController,
} from '../controllers/event-controller.js';
import {
  BrowserController,
  createBrowserController,
} from '../controllers/browser-controller.js';
import {
  WorktreeController,
  createWorktreeController,
} from '../controllers/worktree-controller.js';
import {
  AgentController,
  createAgentController,
} from '../controllers/agent-controller.js';

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
  private agentEventHandler: AgentEventHandler;
  private skillLoader: SkillLoader;
  private agentFactory: AgentFactory;
  private authProvider: AuthProvider;
  private apnsService: APNSService | null = null;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;
  private initialized = false;
  private embeddingService: EmbeddingService | null = null;
  private vectorRepo: VectorRepository | null = null;

  // Internal coordinator for agent execution
  private agentRunner: AgentRunner;

  // Notification service (internal)
  private notificationController!: NotificationController;

  // ==========================================================================
  // Public Controllers (direct access pattern: orchestrator.{controller}.*)
  // ==========================================================================

  /** Event query and mutation with linearization */
  readonly events: EventController;

  /** Browser streaming operations */
  readonly browser: BrowserController;

  /** Git worktree operations */
  readonly worktree: WorktreeController;

  /** Agent execution */
  readonly agent: AgentController;

  /** Session lifecycle management */
  readonly sessions: SessionManager;

  /** Context management and compaction */
  readonly context: ContextOps;

  /** Todo and backlog management */
  readonly todos: TodoController;

  /** Model switching */
  readonly models: ModelController;

  /** Subagent spawning and management */
  readonly subagents: SubagentOperations;

  constructor(config: EventStoreOrchestratorConfig) {
    super();

    // Use injected EventStore (for testing) or create new one
    if (config.eventStore) {
      this.eventStore = config.eventStore;
    } else {
      const eventStoreDbPath = config.eventStoreDbPath ??
        path.join(os.homedir(), '.tron', 'database', 'prod.db');
      this.eventStore = new EventStore(eventStoreDbPath);
    }

    // Initialize WorktreeCoordinator
    this.worktreeCoordinator = createWorktreeCoordinator(this.eventStore, {
      isolationMode: config.worktree?.isolationMode ?? 'lazy',
      branchPrefix: config.worktree?.branchPrefix ?? 'session/',
      autoCommitOnRelease: config.worktree?.autoCommitOnRelease ?? true,
      deleteWorktreeOnRelease: config.worktree?.deleteWorktreeOnRelease ?? true,
      preserveBranches: config.worktree?.preserveBranches ?? true,
      appendEvent: (sessionId, type, payload) =>
        this.appendWorktreeEvent(sessionId, type, payload),
      ...config.worktree,
    });

    // Initialize BrowserService
    this.browserService = new BrowserService({ headless: true });

    // Initialize SubagentOperations (delegated module)
    // Note: agent.run() is a lazy callback - by the time it's invoked, AgentController will be initialized
    this.subagents = createSubagentOperations({
      eventStore: this.eventStore,
      getActiveSession: (sessionId: string) => this.activeSessions.get(sessionId),
      createSession: (options) => this.sessions.createSession(options),
      runAgent: (options) => this.agent.run(options),
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
    this.sessions = createSessionManager({
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
      loadWorkspaceMemory: (workspacePath, options) => this.loadWorkspaceMemory(workspacePath, options),
    });

    // Initialize ContextOps (delegated module)
    this.context = createContextOps({
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
    // Load external service API keys from ~/.tron/auth.json
    const braveAuth = getServiceAuthSync('brave');
    const exaAuth = getServiceAuthSync('exa');
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const self = this;

    this.agentFactory = createAgentFactory({
      getAuthForProvider: (model) => this.authProvider.getAuthForProvider(model),
      spawnSubsession: (parentId, params, toolCallId) => this.subagents.spawnSubsession(parentId, params, toolCallId),
      querySubagent: (sessionId, queryType, limit) => this.subagents.querySubagent(sessionId, queryType, limit),
      waitForSubagents: (sessionIds, mode, timeout) => this.waitForSubagents(sessionIds, mode, timeout),
      forwardAgentEvent: (sessionId, event) => this.forwardAgentEvent(sessionId, event),
      getSubagentTrackerForSession: (sessionId) => this.activeSessions.get(sessionId)?.subagentTracker,
      onTodosUpdated: async (sessionId, todos) => this.todos.handleTodosUpdated(sessionId, todos),
      generateTodoId: () => `todo_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`,
      dbPath: this.eventStore.dbPath,
      get embeddingService() { return self.embeddingService ?? undefined; },
      get vectorRepo() { return self.vectorRepo ?? undefined; },
      braveSearchApiKey: braveAuth?.apiKey,
      exaApiKey: exaAuth?.apiKey,
      blockedWebDomains: config.blockedWebDomains,
      onNotify: this.apnsService ? async (sessionId, notification, toolCallId) => {
        return this.notificationController.sendNotification(sessionId, notification, toolCallId);
      } : undefined,
      browserService: this.browserService ? {
        execute: (sid, action, params) => this.browserService.execute(sid, action, params),
        createSession: async (sid) => { await this.browserService.createSession(sid); },
        startScreencast: async (sid, options) => { await this.browserService.startScreencast(sid, options); },
        hasSession: (sid) => this.browserService.hasSession(sid),
      } : undefined,
      memoryConfig: {
        appendEvent: async (sessionId, type, payload) => {
          const active = this.activeSessions.get(sessionId);
          if (active?.sessionContext) {
            const event = await active.sessionContext.appendEvent(type, payload);
            if (event) return { id: event.id };
          }
          const event = await this.eventStore.append({
            sessionId: sessionId as SessionId,
            type,
            payload,
          });
          return { id: event.id };
        },
        getEventsBySession: (sessionId) =>
          this.eventStore.getEventsBySession(sessionId as SessionId),
        emitMemoryUpdated: (data) => this.emit('memory_updated', data),
        getTokenRatio: (sessionId) => {
          const active = this.activeSessions.get(sessionId);
          if (!active?.agent) return 0;
          const snapshot = active.agent.getContextManager().getSnapshot();
          return snapshot.usagePercent / 100;
        },
        getRecentEventTypes: (sid) => this.getRecentEventTypesForSession(sid),
        getRecentToolCalls: (sid) => this.getRecentToolCallsForSession(sid),
        executeCompaction: async (sessionId) => {
          const active = this.activeSessions.get(sessionId);
          if (!active?.agent) return { success: false };
          if (!active.agent.canAutoCompact()) return { success: false };
          try {
            const result = await active.agent.attemptCompaction('threshold_exceeded');
            return { success: result.success };
          } catch {
            return { success: false };
          }
        },
        embedMemory: async (eventId, workspaceId, payload) => {
          if (!this.embeddingService?.isReady() || !this.vectorRepo) return;
          const text = buildEmbeddingText(payload as unknown as MemoryLedgerPayload);
          const embedding = await this.embeddingService.embedSingle(text);
          this.vectorRepo.store(eventId, workspaceId, embedding);
        },
        getWorkspaceId: (sessionId) => {
          // Synchronous lookup — session row includes workspace_id
          try {
            const db = this.eventStore.getDatabase();
            const row = db.prepare('SELECT workspace_id FROM sessions WHERE id = ?').get(sessionId) as { workspace_id: string } | null;
            return row?.workspace_id ?? '';
          } catch {
            return '';
          }
        },
      },
    });

    // Forward browser events
    this.browserService.on('browser.frame', (frame) => {
      this.emit('browser.frame', frame);
    });
    this.browserService.on('browser.closed', (sessionId) => {
      this.emit('browser.closed', sessionId);
    });

    // Initialize TodoController (delegated module)
    this.todos = createTodoController({
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
      buildSubagentResultsContext: (active) => this.subagents.buildSubagentResultsContext(active),
    });

    // Initialize ModelController (extracted model switching coordinator)
    this.models = createModelController({
      eventStore: this.eventStore,
      authProvider: this.authProvider,
      getActiveSession: (sessionId) => this.activeSessions.get(sessionId),
    });

    // Initialize EventController (event query and mutation with linearization)
    this.events = createEventController({
      eventStore: this.eventStore,
      getActiveSession: (sessionId) => this.activeSessions.get(sessionId),
      getAllActiveSessions: () => this.activeSessions.entries(),
      onEventCreated: (event, sessionId) => {
        this.emit('event_new', { event, sessionId });
      },
    });

    // Initialize BrowserController (browser streaming operations)
    this.browser = createBrowserController({
      browserService: this.browserService,
    });

    // Initialize WorktreeController (git worktree operations)
    this.worktree = createWorktreeController({
      worktreeCoordinator: this.worktreeCoordinator,
      getActiveSession: (sessionId) => this.activeSessions.get(sessionId),
    });

    // Initialize AgentController (agent execution)
    this.agent = createAgentController({
      agentRunner: this.agentRunner,
      getActiveSession: (sessionId) => this.activeSessions.get(sessionId),
      resumeSession: (sessionId) => this.sessions.resumeSession(sessionId),
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

    // Initialize blob storage for large tool results
    const blobStore = this.eventStore.getBlobStore();
    this.agentEventHandler.setBlobStore(blobStore);

    // Initialize vector search from EventStore's sqlite-vec
    this.vectorRepo = this.eventStore.getVectorRepository();

    // Initialize embedding service (async, non-blocking)
    const settings = getSettings();
    const embeddingEnabled = settings.context.memory.embedding?.enabled ?? true;
    if (embeddingEnabled && this.vectorRepo) {
      const embeddingConfig = settings.context.memory.embedding;
      this.embeddingService = new EmbeddingService({
        modelId: embeddingConfig?.model,
        dtype: embeddingConfig?.dtype,
        dimensions: embeddingConfig?.dimensions,
        cacheDir: embeddingConfig?.cacheDir,
      });
      // Fire-and-forget init — don't block server start on model download
      this.embeddingService.initialize().then(() => {
        logger.info('Embedding service ready');
        // Backfill existing memories that don't have vectors
        this.backfillMemoryVectors().catch(err => {
          logger.warn('Memory vector backfill failed', { error: (err as Error).message });
        });
      }).catch(err => {
        logger.warn('Embedding service failed to initialize', { error: (err as Error).message });
        this.embeddingService = null;
      });
    }

    this.startCleanupTimer();
    this.initialized = true;
    logger.info('EventStore orchestrator initialized');
  }

  async shutdown(): Promise<void> {
    this.stopCleanupTimer();

    // End all active sessions
    for (const [sessionId, _active] of this.activeSessions.entries()) {
      try {
        await this.sessions.endSession(sessionId);
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
  // Core Accessors
  // ===========================================================================

  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.activeSessions.get(sessionId);
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
  // Private Methods (test-exposed via any cast)
  // ===========================================================================

  /**
   * Load skill context for a prompt. Delegates to SkillLoader.
   * @internal Exposed for testing via (orchestrator as any).loadSkillContextForPrompt
   */
  ['loadSkillContextForPrompt'] = async (
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<string> => {
    return this.skillLoader.loadSkillContextForPrompt(
      {
        sessionId: active.sessionId,
        skillTracker: active.skillTracker,
        sessionContext: active.sessionContext!,
      },
      options
    );
  };

  /**
   * Track skills for a prompt. Delegates to SkillLoader.
   * @internal Exposed for testing via (orchestrator as any).trackSkillsForPrompt
   */
  ['trackSkillsForPrompt'] = async (
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> => {
    return this.skillLoader.trackSkillsForPrompt(
      {
        sessionId: active.sessionId,
        skillTracker: active.skillTracker,
        sessionContext: active.sessionContext!,
      },
      options
    );
  };

  // ===========================================================================
  // Agent Factory (delegated to AgentFactory)
  // ===========================================================================

  private async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string,
    isSubagent?: boolean,
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
   * Append a worktree event, using linearized SessionContext persistence for
   * active sessions and direct EventStore appends otherwise.
   */
  private async appendWorktreeEvent(
    sessionId: SessionId,
    type: string,
    payload: Record<string, unknown>
  ): Promise<string> {
    const active = this.activeSessions.get(sessionId);
    if (active?.sessionContext) {
      const event = await active.sessionContext.appendEvent(
        type as EventType,
        payload
      );
      if (!event) {
        throw new Error(`Failed to append ${type} event for active session ${sessionId}`);
      }
      return event.id;
    }

    const event = await this.eventStore.append({
      sessionId,
      type: type as EventType,
      payload,
    });
    return event.id;
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

  // ===========================================================================
  // Private Internal Helpers
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

  /**
   * Get recent event types for a session since the last compaction.
   * Used by the CompactionTrigger to detect progress signals (e.g. worktree.commit).
   */
  private getRecentEventTypesForSession(sessionId: string): Promise<string[]> {
    return this.getRecentEventsForSession(sessionId).then(events =>
      events.map(e => e.type)
    );
  }

  /**
   * Get recent Bash tool commands for a session since the last compaction.
   * Used by the CompactionTrigger to detect progress signals (e.g. git push, gh pr create).
   */
  private getRecentToolCallsForSession(sessionId: string): Promise<string[]> {
    return this.getRecentEventsForSession(sessionId).then(events => {
      const commands: string[] = [];
      for (const event of events) {
        if (event.type === 'tool.call') {
          const payload = event.payload as Record<string, unknown>;
          if (payload.name === 'Bash') {
            const args = payload.arguments as Record<string, unknown> | undefined;
            const command = args?.command;
            if (typeof command === 'string') {
              commands.push(command);
            }
          }
        }
      }
      return commands;
    });
  }

  /**
   * Get events since the last compaction boundary (or all events if no compaction).
   * Fetches from EventStore — the data is already persisted, no duplication needed.
   */
  private async getRecentEventsForSession(sessionId: string): Promise<TronSessionEvent[]> {
    try {
      const allEvents = await this.eventStore.getEventsBySession(sessionId as SessionId);
      // Find the last compact.boundary event — everything after it is "recent"
      let lastCompactionIdx = -1;
      for (let i = allEvents.length - 1; i >= 0; i--) {
        if (allEvents[i]!.type === 'compact.boundary') {
          lastCompactionIdx = i;
          break;
        }
      }
      const recent = allEvents.slice(lastCompactionIdx + 1);
      logger.debug('Queried recent events for memory system', {
        sessionId,
        totalEvents: allEvents.length,
        recentEvents: recent.length,
        hadCompactionBoundary: lastCompactionIdx >= 0,
      });
      return recent;
    } catch (error) {
      logger.warn('Failed to query recent events for memory system', {
        sessionId,
        error: (error as Error).message,
      });
      return [];
    }
  }

  // ===========================================================================
  // Embedding / Vector Search
  // ===========================================================================

  getEmbeddingService(): EmbeddingService | null {
    return this.embeddingService;
  }

  private async loadWorkspaceMemory(
    workspacePath: string,
    options?: { count?: number }
  ): Promise<{ content: string; count: number; tokens: number } | undefined> {
    const workspace = await this.eventStore.getWorkspaceByPath(workspacePath);
    if (!workspace) return undefined;

    const count = Math.max(1, Math.min(options?.count ?? 5, 10));

    const ledgerEvents = await this.eventStore.getEventsByWorkspaceAndTypes(
      workspace.id,
      ['memory.ledger' as EventType],
      { limit: count }
    );

    if (ledgerEvents.length === 0) return undefined;

    // Events come back DESC, reverse for chronological display
    const entries = ledgerEvents.reverse().map(e => {
      const p = e.payload as unknown as MemoryLedgerPayload;
      const parts = [`### ${p.title}`];
      if (p.lessons?.length) parts.push(p.lessons.map(l => `- ${l}`).join('\n'));
      if (p.decisions?.length) parts.push(p.decisions.map(d => `- ${d.choice}: ${d.reason}`).join('\n'));
      return parts.join('\n');
    });

    const content = `# Memory\n\n## Recent sessions in this workspace\n\n${entries.join('\n\n')}`;
    const tokens = Math.ceil(content.length / 4);

    return { content, count: ledgerEvents.length, tokens };
  }

  private async backfillMemoryVectors(): Promise<void> {
    if (!this.embeddingService?.isReady() || !this.vectorRepo) return;

    const db = this.eventStore.getDatabase();
    const unembedded = db.prepare(`
      SELECT e.id, e.workspace_id, e.payload
      FROM events e
      LEFT JOIN memory_vectors v ON e.id = v.event_id
      WHERE e.type = 'memory.ledger' AND v.event_id IS NULL
    `).all() as Array<{ id: string; workspace_id: string; payload: string }>;

    if (unembedded.length === 0) return;

    logger.info('Backfilling memory vectors', { count: unembedded.length });

    let embedded = 0;
    for (const event of unembedded) {
      try {
        const payload = JSON.parse(event.payload) as MemoryLedgerPayload;
        const text = buildEmbeddingText(payload);
        const embedding = await this.embeddingService.embedSingle(text);
        this.vectorRepo.store(event.id, event.workspace_id, embedding);
        embedded++;
      } catch (err) {
        logger.warn('Failed to embed memory event', {
          eventId: event.id,
          error: (err as Error).message,
        });
      }
    }

    logger.info('Memory vector backfill complete', { embedded, total: unembedded.length });
  }

  private startCleanupTimer(): void {
    this.cleanupTimer = setInterval(() => {
      this.sessions.cleanupInactiveSessions();
    }, 5 * 60 * 1000);
  }

  private stopCleanupTimer(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }
}
