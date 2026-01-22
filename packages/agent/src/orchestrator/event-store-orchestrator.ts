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
import {
  createLogger,
  TronAgent,
  EventStore,
  WorktreeCoordinator,
  createWorktreeCoordinator,
  loadServerAuth,
  SubAgentTracker,
  BacklogService,
  createBacklogService,
  type TurnResult,
  type TronEvent,
  type EventMessage,
  type EventSessionState,
  type TronSessionEvent,
  type AppendEventOptions,
  type EventId,
  type SessionId,
  type EventType,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type UserContent,
  type SpawnSubagentParams,
  type SpawnTmuxAgentParams,
  type SubagentQueryType,
  type SubagentStatusInfo,
  type SubagentEventInfo,
  type SubagentLogInfo,
  type SubagentResult,
  type TodoItem,
  type BackloggedTask,
  type NotifyAppResult,
  withLoggingContext,
} from '../index.js';
import { BrowserService } from '../external/browser/index.js';
import { normalizeContentBlocks } from '../utils/content-normalizer.js';
import {
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './worktree-ops.js';
import {
  SubagentOperations,
  createSubagentOperations,
} from './subagent-ops.js';
import {
  AgentEventHandler,
  createAgentEventHandler,
} from './agent-event-handler.js';
import {
  SkillLoader,
  createSkillLoader,
} from './skill-loader.js';
import {
  SessionManager,
  createSessionManager,
} from './session-manager.js';
import {
  ContextOps,
  createContextOps,
} from './context-ops.js';
import {
  AgentFactory,
  createAgentFactory,
} from './agent-factory.js';
import {
  AuthProvider,
  createAuthProvider,
} from './auth-provider.js';
import {
  APNSService,
  createAPNSService,
  type APNSNotification,
} from '../external/apns/index.js';
import {
  type EventStoreOrchestratorConfig,
  type ActiveSession,
  type AgentRunOptions,
  type AgentEvent,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
  type WorktreeInfo,
} from './types.js';

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
  private backlogService: BacklogService | null = null;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;
  private initialized = false;

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
      onTodosUpdated: async (sessionId, todos) => this.handleTodosUpdated(sessionId, todos),
      generateTodoId: () => `todo_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`,
      onNotify: this.apnsService ? async (sessionId, notification, toolCallId) => {
        return this.sendNotification(sessionId, notification, toolCallId);
      } : undefined,
      browserService: this.browserService ? {
        execute: (sid, action, params) => this.browserService.execute(sid, action as any, params),
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

    // Initialize BacklogService for todo backlog persistence (must be after eventStore.initialize())
    this.backlogService = createBacklogService(this.eventStore.getDatabase());

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

  private getBacklogService(): BacklogService {
    if (!this.backlogService) {
      throw new Error('BacklogService not initialized. Call initialize() first.');
    }
    return this.backlogService;
  }

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

    // Update processing state (sync both for backward compatibility)
    active.isProcessing = true;
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(true);

    // Wrap entire agent run with logging context for session correlation
    return withLoggingContext(
      { sessionId: options.sessionId },
      async () => {
    try {
      // CRITICAL: Wait for any pending stream events to complete before appending message events
      // This prevents race conditions where stream events (turn_start, etc.) capture wrong parentId
      await active.sessionContext!.flushEvents();

      // Track skills and load content BEFORE building user content
      // Skill context is now injected as a system block (not user message)
      // Also pass plan mode callback to enable skill-triggered plan mode
      const planModeCallback = {
        enterPlanMode: async (skillName: string, blockedTools: string[]) => {
          await this.enterPlanMode(active.sessionId, { skillName, blockedTools });
        },
        isInPlanMode: () => this.isInPlanMode(active.sessionId),
      };
      const skillContext = await this.skillLoader.loadSkillContextForPrompt(
        {
          sessionId: active.sessionId,
          skillTracker: active.skillTracker,
          sessionContext: active.sessionContext!,
        },
        options,
        planModeCallback
      );

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

      // Check for pending sub-agent results and inject them
      const subagentResultsContext = this.buildSubagentResultsContext(active);
      if (subagentResultsContext) {
        logger.info('[SUBAGENT] Injecting pending sub-agent results', {
          sessionId: active.sessionId,
          contextLength: subagentResultsContext.length,
          preview: subagentResultsContext.substring(0, 200),
        });
        active.agent.setSubagentResultsContext(subagentResultsContext);
      } else {
        active.agent.setSubagentResultsContext(undefined);
      }

      // Build and inject todo context if tasks exist
      const todoContext = active.todoTracker.buildContextString();
      if (todoContext) {
        logger.info('[TODO] Injecting todo context', {
          sessionId: active.sessionId,
          contextLength: todoContext.length,
          todoCount: active.todoTracker.count,
          summary: active.todoTracker.buildSummaryString(),
        });
        active.agent.setTodoContext(todoContext);
      } else {
        active.agent.setTodoContext(undefined);
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

      // Record user message event (linearized via SessionContext)
      // Build payload with optional skills for chat history display
      const userMsgPayload: { content: unknown; skills?: { name: string; source: string }[] } = {
        content: messageContent,
      };
      if (options.skills && options.skills.length > 0) {
        userMsgPayload.skills = options.skills.map(s => ({ name: s.name, source: s.source }));
      }

      const userMsgEvent = await active.sessionContext!.appendEvent('message.user', userMsgPayload);
      // Track eventId for context manager message (user message will be added to context by agent.run)
      if (userMsgEvent) {
        active.sessionContext!.addMessageEventId(userMsgEvent.id);
        logger.debug('[LINEARIZE] message.user appended', {
          sessionId: active.sessionId,
          eventId: userMsgEvent.id,
        });
      }

      // Set reasoning level if provided (for OpenAI Codex models)
      // Persist event only when level actually changes
      if (options.reasoningLevel && options.reasoningLevel !== active.sessionContext!.getReasoningLevel()) {
        const previousLevel = active.sessionContext!.getReasoningLevel();
        active.agent.setReasoningLevel(options.reasoningLevel);
        active.sessionContext!.setReasoningLevel(options.reasoningLevel);

        // Persist reasoning level change as linearized event
        const reasoningEvent = await active.sessionContext!.appendEvent('config.reasoning_level', {
          previousLevel,
          newLevel: options.reasoningLevel,
        });
        if (reasoningEvent) {
          logger.debug('[LINEARIZE] config.reasoning_level appended', {
            sessionId: active.sessionId,
            eventId: reasoningEvent.id,
            previousLevel,
            newLevel: options.reasoningLevel,
          });
        }
      }

      // Transform content for LLM: convert text file documents to inline text
      // (Claude's document type only supports PDFs, not text files)
      const llmContent = this.skillLoader.transformContentForLLM(messageContent);

      // Run agent with transformed content
      const runResult = await active.agent.run(llmContent);
      // Update activity timestamp
      active.lastActivity = new Date();
      active.sessionContext.touch();

      // Handle interrupted runs - PERSIST partial content so it survives session resume
      if (runResult.interrupted) {
        const accumulated = active.sessionContext.getAccumulatedContent();
        logger.info('Agent run interrupted', {
          sessionId: options.sessionId,
          turn: runResult.turns,
          hasPartialContent: !!runResult.partialContent,
          accumulatedTextLength: accumulated.text?.length ?? 0,
          toolCallsCount: accumulated.toolCalls?.length ?? 0,
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
        // Use SessionContext to build content blocks from accumulated state
        // This preserves exact interleaving order of text and tool calls
        const { assistantContent, toolResultContent } = active.sessionContext!.buildInterruptedContent();

        // Only persist if there's actual content
        if (assistantContent.length > 0 || toolResultContent.length > 0) {
          // Wait for any pending stream events
          await active.sessionContext!.flushEvents();

          // 1. Persist assistant message with tool_use blocks
          if (assistantContent.length > 0) {
            const normalizedAssistantContent = normalizeContentBlocks(assistantContent);

            const assistantMsgEvent = await active.sessionContext!.appendEvent('message.assistant', {
              content: normalizedAssistantContent,
              tokenUsage: runResult.totalTokenUsage,
              turn: runResult.turns || 1,
              model: active.sessionContext!.getModel(),
              stopReason: 'interrupted',
              interrupted: true,
            });

            if (assistantMsgEvent) {
              logger.info('Persisted interrupted assistant message', {
                sessionId: active.sessionId,
                eventId: assistantMsgEvent.id,
                contentBlocks: normalizedAssistantContent.length,
                hasAccumulatedContent: active.sessionContext!.hasAccumulatedContent(),
              });
            }
          }

          // 2. Persist tool results as user message (like normal flow)
          // This ensures tool results appear in the session history
          if (toolResultContent.length > 0) {
            const normalizedToolResults = normalizeContentBlocks(toolResultContent);

            const toolResultEvent = await active.sessionContext!.appendEvent('message.user', {
              content: normalizedToolResults,
            });

            if (toolResultEvent) {
              logger.info('Persisted tool results for interrupted session', {
                sessionId: active.sessionId,
                eventId: toolResultEvent.id,
                resultCount: normalizedToolResults.length,
              });
            }
          }
        }

        // Persist notification.interrupted event as first-class ledger entry
        const interruptNotificationEvent = await active.sessionContext!.appendEvent('notification.interrupted', {
          timestamp: new Date().toISOString(),
          turn: runResult.turns || 1,
        });

        if (interruptNotificationEvent) {
          logger.info('Persisted notification.interrupted event', {
            sessionId: active.sessionId,
            eventId: interruptNotificationEvent.id,
          });
        }

        // Mark session as interrupted in metadata
        active.wasInterrupted = true;

        // Clear turn tracking state via SessionContext
        active.sessionContext!.onAgentEnd();

        return [runResult] as unknown as TurnResult[];
      }

      // Wait for all linearized events (turn_end creates message.assistant and tool_results per-turn)
      // to complete before returning
      await active.sessionContext!.flushEvents();

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

      // Emit agent.complete AFTER all linearized events are persisted
      // This ensures events (message.assistant, tool.call, tool.result)
      // are in the database before iOS receives this and syncs
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

      // Store error.agent event for agent-level errors (linearized)
      try {
        // CRITICAL: Wait for any pending events before appending
        await active.sessionContext!.flushEvents();
        const errorEvent = await active.sessionContext!.appendEvent('error.agent', {
          error: error instanceof Error ? error.message : String(error),
          code: error instanceof Error ? error.name : undefined,
          recoverable: false,
        });
        if (errorEvent) {
          logger.debug('[LINEARIZE] error.agent appended', {
            sessionId: active.sessionId,
            eventId: errorEvent.id,
          });
        }
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

      // Emit agent.complete for error case (after pending events have been flushed)
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
      // Clear processing state (sync both for backward compatibility)
      active.isProcessing = false;
      active.sessionContext.setProcessing(false);
    }
      }); // End withLoggingContext
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

    // Clear processing state (sync both for backward compatibility)
    active.isProcessing = false;
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(false);
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

    // Get active session for linearized append (if session is active)
    const active = this.activeSessions.get(sessionId);

    // P0 FIX: Prevent model switch during active agent processing
    // Modifying agent.model while agent.run() is in-flight causes inconsistent model usage
    if (active?.isProcessing) {
      throw new Error('Cannot switch model while agent is processing');
    }

    // Append model switch event (linearized via SessionContext for active sessions)
    let modelSwitchEvent: TronSessionEvent | null = null;

    if (active?.sessionContext) {
      modelSwitchEvent = await active.sessionContext.appendEvent('config.model_switch', {
        previousModel,
        newModel: model,
      });
    } else {
      // Session not active - direct append is safe (no concurrent events)
      modelSwitchEvent = await this.eventStore.append({
        sessionId: sessionId as SessionId,
        type: 'config.model_switch',
        payload: {
          previousModel,
          newModel: model,
        },
      });
    }

    if (modelSwitchEvent) {
      logger.debug('[LINEARIZE] config.model_switch appended', {
        sessionId,
        eventId: modelSwitchEvent.id,
      });
    }

    // CRITICAL: Persist model change to session in database
    // Without this, the model reverts when session is reloaded
    await this.eventStore.updateLatestModel(sessionId as SessionId, model);
    logger.debug('[MODEL_SWITCH] Model persisted to database', { sessionId, model });

    // Update active session if exists
    if (active) {
      // Get auth for the new model (handles Codex OAuth vs standard auth)
      const newAuth = await this.authProvider.getAuthForProvider(model);
      logger.debug('[MODEL_SWITCH] Auth loaded', { sessionId, authType: newAuth.type });

      active.model = model;
      // CRITICAL: Use agent's switchModel() to preserve conversation history
      // Pass the new auth to ensure correct credentials for the new provider
      // Cast is safe - GoogleAuth is compatible with UnifiedAuth & { endpoint? }
      active.agent.switchModel(model, undefined, newAuth as any);
      logger.debug('[MODEL_SWITCH] Agent model switched (preserving messages)', { sessionId, model });
    }

    logger.info('Model switched', { sessionId, previousModel, newModel: model });

    return { previousModel, newModel: model };
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
  isInPlanMode(sessionId: string): boolean {
    const active = this.activeSessions.get(sessionId);
    if (!active) return false;
    return active.sessionContext.isInPlanMode();
  }

  /**
   * Get the list of blocked tools for a session
   */
  getBlockedTools(sessionId: string): string[] {
    const active = this.activeSessions.get(sessionId);
    if (!active) return [];
    return active.sessionContext.getBlockedTools();
  }

  /**
   * Check if a specific tool is blocked for a session
   */
  isToolBlocked(sessionId: string, toolName: string): boolean {
    const active = this.activeSessions.get(sessionId);
    if (!active) return false;
    return active.sessionContext.isToolBlocked(toolName);
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
   */
  async enterPlanMode(
    sessionId: string,
    options: { skillName: string; blockedTools: string[] }
  ): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    if (active.sessionContext.isInPlanMode()) {
      throw new Error(`Session ${sessionId} is already in plan mode`);
    }

    // Append plan.mode_entered event
    const event = await active.sessionContext.appendEvent('plan.mode_entered', {
      skillName: options.skillName,
      blockedTools: options.blockedTools,
    });

    // Update plan mode state
    active.sessionContext.enterPlanMode(options.skillName, options.blockedTools);

    logger.info('Plan mode entered', {
      sessionId,
      skillName: options.skillName,
      blockedTools: options.blockedTools,
      eventId: event?.id,
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
   */
  async exitPlanMode(
    sessionId: string,
    options: { reason: 'approved' | 'cancelled' | 'timeout'; planPath?: string }
  ): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    if (!active.sessionContext.isInPlanMode()) {
      throw new Error(`Session ${sessionId} is not in plan mode`);
    }

    // Build payload (only include planPath if present)
    const payload: Record<string, unknown> = { reason: options.reason };
    if (options.planPath) {
      payload.planPath = options.planPath;
    }

    // Append plan.mode_exited event
    const event = await active.sessionContext.appendEvent('plan.mode_exited', payload);

    // Update plan mode state
    active.sessionContext.exitPlanMode();

    logger.info('Plan mode exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
      eventId: event?.id,
    });

    this.emit('plan.mode_exited', {
      sessionId,
      reason: options.reason,
      planPath: options.planPath,
    });
  }

  // ===========================================================================
  // Todo Operations
  // ===========================================================================

  /**
   * Handle todos being updated via the TodoWrite tool.
   * Updates the tracker and persists a todo.write event.
   */
  private async handleTodosUpdated(sessionId: string, todos: TodoItem[]): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Persist todo.write event (linearized via SessionContext)
    const event = await active.sessionContext!.appendEvent('todo.write', {
      todos,
      trigger: 'tool',
    });

    // Update the tracker
    if (event) {
      active.todoTracker.setTodos(todos, event.id);
    }

    logger.debug('Todos updated', {
      sessionId,
      todoCount: todos.length,
      eventId: event?.id,
    });

    // Emit event for UI updates
    this.emit('todos_updated', {
      sessionId,
      todos,
    });
  }

  /**
   * Get current todos for a session.
   * Used by RPC handlers.
   */
  getTodos(sessionId: string): TodoItem[] {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return [];
    }
    return active.todoTracker.getAllTodos();
  }

  /**
   * Get todo summary for a session.
   */
  getTodoSummary(sessionId: string): string {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return 'no tasks';
    }
    return active.todoTracker.buildSummaryString();
  }

  // ===========================================================================
  // Push Notifications
  // ===========================================================================

  /**
   * Send a push notification to all registered devices.
   * Any agent/session can trigger notifications globally.
   * Used by the NotifyApp tool.
   */
  private async sendNotification(
    sessionId: string,
    notification: {
      title: string;
      body: string;
      data?: Record<string, string>;
      priority?: 'high' | 'normal';
      sound?: string;
      badge?: number;
    },
    toolCallId: string
  ): Promise<NotifyAppResult> {
    if (!this.apnsService) {
      return { successCount: 0, failureCount: 0, errors: ['APNS not configured'] };
    }

    // Get ALL active device tokens (global notification)
    const db = this.eventStore.getDatabase();
    if (!db) {
      return { successCount: 0, failureCount: 0, errors: ['Database not available'] };
    }

    const tokens = db
      .prepare(`
        SELECT device_token, environment
        FROM device_tokens
        WHERE is_active = 1
      `)
      .all() as Array<{ device_token: string; environment: string }>;

    if (tokens.length === 0) {
      logger.debug('No device tokens registered');
      return { successCount: 0, failureCount: 0 };
    }

    // Build APNS notification payload
    const apnsNotification: APNSNotification = {
      title: notification.title,
      body: notification.body,
      data: {
        ...notification.data,
        sessionId, // Include sessionId for deep linking to the sending session
        toolCallId, // Include toolCallId so iOS can scroll to the notification chip
      },
      priority: notification.priority,
      sound: notification.sound,
      badge: notification.badge,
      threadId: sessionId, // Group notifications by session
    };

    // Send to all registered devices
    const deviceTokens = tokens.map((t) => t.device_token);
    const results = await this.apnsService.sendToMany(deviceTokens, apnsNotification);

    // Handle invalid tokens (APNS 410 = unregistered)
    for (const result of results) {
      if (!result.success && result.reason === 'Unregistered') {
        // Mark token as invalid
        db.prepare('UPDATE device_tokens SET is_active = 0 WHERE device_token = ?')
          .run(result.deviceToken);
        logger.info('Marked unregistered device token as inactive', {
          deviceToken: result.deviceToken.substring(0, 8) + '...',
        });
      }
    }

    const successCount = results.filter((r) => r.success).length;
    const failureCount = results.filter((r) => !r.success).length;
    const errors = results
      .filter((r) => !r.success && r.error)
      .map((r) => r.error!);

    return { successCount, failureCount, errors: errors.length > 0 ? errors : undefined };
  }

  // ===========================================================================
  // Backlog Operations
  // ===========================================================================

  /**
   * Get backlogged tasks for a workspace.
   * Used by RPC handlers for iOS task visibility.
   */
  getBacklog(workspaceId: string, options?: { includeRestored?: boolean; limit?: number }): BackloggedTask[] {
    return this.getBacklogService().getBacklog(workspaceId, options);
  }

  /**
   * Get count of unrestored backlogged tasks for a workspace.
   */
  getBacklogCount(workspaceId: string): number {
    return this.getBacklogService().getUnrestoredCount(workspaceId);
  }

  /**
   * Restore tasks from backlog to a session.
   * Creates new TodoItems in the session and records a todo.write event.
   */
  async restoreFromBacklog(sessionId: string, taskIds: string[]): Promise<TodoItem[]> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    // Generate IDs for restored tasks
    const generateId = () => `todo_${crypto.randomUUID().slice(0, 8)}`;

    // Restore tasks from backlog (marks them as restored in DB)
    const restoredTodos = this.getBacklogService().restoreTasks(taskIds, sessionId, generateId);

    if (restoredTodos.length === 0) {
      return [];
    }

    // Merge with existing todos
    const existingTodos = active.todoTracker.getAllTodos();
    const newTodoList = [...existingTodos, ...restoredTodos];

    // Record todo.write event with merged list
    const event = await active.sessionContext!.appendEvent('todo.write', {
      todos: newTodoList,
      trigger: 'restore',
    });

    if (event) {
      active.todoTracker.setTodos(newTodoList, event.id);
    }

    // Emit event for WebSocket broadcast
    this.emit('todos_updated', {
      sessionId,
      todos: newTodoList,
      restoredCount: restoredTodos.length,
    });

    logger.info('Tasks restored from backlog', {
      sessionId,
      requestedCount: taskIds.length,
      restoredCount: restoredTodos.length,
      totalTodos: newTodoList.length,
    });

    return restoredTodos;
  }

  /**
   * Move incomplete todos to backlog for a session.
   * Called internally when context is cleared.
   */
  async backlogIncompleteTodos(
    sessionId: string,
    workspaceId: string,
    reason: 'session_clear' | 'context_compact' | 'session_end'
  ): Promise<number> {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      return 0;
    }

    const incompleteTodos = active.todoTracker.getIncomplete();
    if (incompleteTodos.length === 0) {
      return 0;
    }

    this.getBacklogService().backlogTasks(incompleteTodos, sessionId, workspaceId, reason);

    logger.info('Incomplete todos backlogged', {
      sessionId,
      workspaceId,
      reason,
      count: incompleteTodos.length,
    });

    return incompleteTodos.length;
  }

}
