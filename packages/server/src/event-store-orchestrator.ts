/**
 * @fileoverview EventStore-backed Session Orchestrator
 *
 * Manages multiple agent sessions using the EventStore for persistence.
 * This is the unified event-sourced architecture for session management.
 */
import { EventEmitter } from 'events';
import * as path from 'path';
import * as fs from 'fs';
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
  getTronDataDir,
  detectProviderFromModel,
  KeywordSummarizer,
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
  type CurrentTurnToolCall,
  type ContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type Summarizer,
} from '@tron/core';
import {
  normalizeContentBlocks,
  truncateString,
  MAX_TOOL_RESULT_SIZE,
} from './utils/content-normalizer.js';
import {
  appendEventLinearized as appendEventLinearizedImpl,
  flushPendingEvents as flushPendingEventsImpl,
  flushAllPendingEvents as flushAllPendingEventsImpl,
} from './orchestrator/event-linearizer.js';
import {
  buildWorktreeInfo,
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from './orchestrator/worktree-ops.js';
import {
  type EventStoreOrchestratorConfig,
  type ActiveSession,
  type AgentRunOptions,
  type AgentEvent,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
  type RewindResult,
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
  RewindResult,
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
      // Initialize current turn tracking for resume support (accumulated across all turns)
      currentTurnAccumulatedText: '',
      currentTurnToolCalls: [],
      currentTurnContentSequence: [],
      // Initialize per-turn tracking (cleared after each message.assistant)
      thisTurnContent: [],
      thisTurnToolCalls: new Map(),
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

    // Create agent (use resolved working directory path)
    const agent = await this.createAgentForSession(
      session.id,
      workingDir.path,
      session.latestModel
    );

    // Load conversation history from event store and populate agent
    // This follows parent_id chain for forked sessions to include parent history
    const eventMessages = await this.eventStore.getMessagesAtHead(session.id);
    for (const msg of eventMessages) {
      // Convert event store messages to agent message format
      // Event store only returns 'user' and 'assistant' roles
      // Note: Content block types differ slightly between event store (Anthropic API format)
      // and agent types, but they are compatible at runtime for common cases (text, tool_use)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent.addMessage(msg as any);
    }
    logger.info('Session history loaded', {
      sessionId,
      messageCount: eventMessages.length,
    });

    this.activeSessions.set(sessionId, {
      sessionId: session.id,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model: session.latestModel,
      workingDir,
      currentTurn: session.turnCount ?? 0,
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

      // Set reasoning level if provided (for OpenAI Codex models)
      if (options.reasoningLevel) {
        active.agent.setReasoningLevel(options.reasoningLevel);
      }

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

      // Wait for all linearized events (turn_end creates message.assistant and tool_results per-turn)
      // to complete before returning
      await active.appendPromiseChain;

      logger.debug('Agent run completed', {
        sessionId: active.sessionId,
        turns: runResult.turns,
        stoppedReason: runResult.stoppedReason,
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
      // Detect new provider type and load appropriate auth
      const newProviderType = detectProviderFromModel(model);
      let newAuth: ServerAuth;

      if (newProviderType === 'openai-codex') {
        // Load Codex-specific OAuth tokens
        const codexTokens = this.loadCodexTokens();
        if (!codexTokens) {
          throw new Error('OpenAI Codex not authenticated. Sign in via the iOS app or use a different model.');
        }
        newAuth = {
          type: 'oauth',
          accessToken: codexTokens.accessToken,
          refreshToken: codexTokens.refreshToken,
          expiresAt: codexTokens.expiresAt,
        };
        logger.debug('[MODEL_SWITCH] Using Codex OAuth tokens', { sessionId });
      } else {
        // Use cached auth from ~/.tron/auth.json (supports Claude Max OAuth)
        if (!this.cachedAuth || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
          this.cachedAuth = await loadServerAuth();
        }
        if (!this.cachedAuth) {
          throw new Error('No authentication configured. Run `tron login` to authenticate.');
        }
        newAuth = this.cachedAuth;
        logger.debug('[MODEL_SWITCH] Using cached auth', { sessionId, authType: newAuth.type });
      }

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
          messages: 0,
        },
      };
    }
    return active.agent.getContextManager().getSnapshot();
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

  private async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string
  ): Promise<TronAgent> {
    // Detect provider type from model
    const providerType = detectProviderFromModel(model);

    // For OpenAI Codex models, load Codex-specific OAuth tokens
    let auth: ServerAuth;
    if (providerType === 'openai-codex') {
      const codexTokens = this.loadCodexTokens();
      if (!codexTokens) {
        throw new Error('OpenAI Codex not authenticated. Sign in via the iOS app or use a different model.');
      }
      auth = {
        type: 'oauth',
        accessToken: codexTokens.accessToken,
        refreshToken: codexTokens.refreshToken,
        expiresAt: codexTokens.expiresAt,
      };
    } else {
      // Use cached auth from ~/.tron/auth.json (supports Claude Max OAuth)
      // Refresh cache if needed (OAuth tokens expire)
      if (!this.cachedAuth || (this.cachedAuth.type === 'oauth' && this.cachedAuth.expiresAt < Date.now())) {
        this.cachedAuth = await loadServerAuth();
      }

      if (!this.cachedAuth) {
        throw new Error('No authentication configured. Run `tron login` to authenticate with Claude Max or set up API key.');
      }
      auth = this.cachedAuth;
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
   * Load Codex OAuth tokens from file storage
   */
  private loadCodexTokens(): { accessToken: string; refreshToken: string; expiresAt: number } | null {
    try {
      const tokensPath = path.join(getTronDataDir(), 'codex-tokens.json');
      if (fs.existsSync(tokensPath)) {
        const data = fs.readFileSync(tokensPath, 'utf8');
        return JSON.parse(data);
      }
    } catch (error) {
      logger.warn('Failed to load Codex tokens', { error });
    }
    return null;
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
    payload: Record<string, unknown>
  ): void {
    const active = this.activeSessions.get(sessionId);
    if (!active) {
      logger.error('Cannot append event: session not active', { sessionId, type });
      return;
    }
    appendEventLinearizedImpl(this.eventStore, sessionId, active, type, payload);
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

          // Clear THIS TURN's content tracking (for per-turn message.assistant creation)
          // This is separate from accumulated content which persists across turns for catch-up
          active.thisTurnContent = [];
          active.thisTurnToolCalls = new Map();

          // NOTE: We do NOT reset accumulated content here anymore!
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

        // CREATE MESSAGE.ASSISTANT FOR THIS TURN
        // Each turn gets its own message.assistant event with per-turn token data
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
            });

            logger.debug('Created message.assistant for turn', {
              sessionId,
              turn: event.turn,
              contentBlocks: normalizedContent.length,
              tokenUsage: active.lastTurnTokenUsage,
              latency: turnLatency,
            });
          }

          // Store tool results as message.user AFTER message.assistant, BEFORE next turn
          // This ensures proper sequencing: user → assistant(tool_use) → user(tool_result) → assistant(response)
          const completedToolCalls = Array.from(active.thisTurnToolCalls.values())
            .filter(tc => tc.status === 'completed' || tc.status === 'error');

          if (completedToolCalls.length > 0) {
            const toolResultBlocks = completedToolCalls.map(tc => ({
              type: 'tool_result' as const,
              tool_use_id: tc.toolCallId,
              content: tc.result ?? (tc.isError ? 'Error' : '(no output)'),
              is_error: tc.isError ?? false,
            }));

            // Normalize with truncation for large content
            const normalizedToolResults = normalizeContentBlocks(toolResultBlocks);

            logger.debug('Storing tool results for turn', {
              sessionId,
              turn: event.turn,
              resultCount: normalizedToolResults.length,
            });

            // Store tool results as message.user (linearized)
            this.appendEventLinearized(sessionId, 'message.user', {
              content: normalizedToolResults,
            });
          }

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
          },
        });

        // Phase 4: Store turn end event with token usage (linearized)
        this.appendEventLinearized(sessionId, 'stream.turn_end', {
          turn: event.turn,
          tokenUsage: event.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
        });
        break;

      case 'message_update':
        // Accumulate text for resume support (across ALL turns)
        if (active && typeof event.content === 'string') {
          active.currentTurnAccumulatedText += event.content;

          // Track in content sequence for proper interleaving on interrupt (across ALL turns)
          // If the last item is a text item, append to it; otherwise add new text item
          const lastItem = active.currentTurnContentSequence[active.currentTurnContentSequence.length - 1];
          if (lastItem && lastItem.type === 'text') {
            lastItem.text += event.content;
          } else {
            active.currentTurnContentSequence.push({ type: 'text', text: event.content });
          }

          // Also track in THIS TURN's content (for per-turn message.assistant creation)
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
          const toolCallData = {
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.arguments ?? {},
            status: 'running' as const,
            startedAt: timestamp,
          };
          active.currentTurnToolCalls.push(toolCallData);

          // Track in content sequence for proper interleaving on interrupt (across ALL turns)
          active.currentTurnContentSequence.push({
            type: 'tool_ref',
            toolCallId: event.toolCallId,
          });

          // Also track in THIS TURN (for per-turn message.assistant creation)
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
        const resultContent = typeof event.result === 'object' && event.result !== null
          ? (event.result as { content?: string }).content ?? JSON.stringify(event.result)
          : String(event.result ?? '');

        // Update tool call tracking for resume support (across ALL turns)
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

          // Also update THIS TURN's tool call tracking
          const thisTurnToolCall = active.thisTurnToolCalls.get(event.toolCallId);
          if (thisTurnToolCall) {
            thisTurnToolCall.status = event.isError ? 'error' : 'completed';
            thisTurnToolCall.result = resultContent;
            thisTurnToolCall.isError = event.isError ?? false;
            thisTurnToolCall.completedAt = timestamp;
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

  private sessionRowToInfo(
    row: any,
    isActive: boolean,
    workingDir?: WorkingDirectory
  ): SessionInfo {
    return {
      sessionId: row.id,
      workingDirectory: workingDir?.path ?? row.workingDirectory,
      // Use latestModel from DB, but expose as 'model' for backward compatibility
      model: row.latestModel,
      messageCount: row.messageCount ?? 0,
      eventCount: row.eventCount ?? 0,
      inputTokens: row.totalInputTokens ?? 0,
      outputTokens: row.totalOutputTokens ?? 0,
      cost: row.totalCost ?? 0,
      createdAt: row.createdAt,
      lastActivity: row.lastActivityAt,
      isActive,
      worktree: workingDir ? buildWorktreeInfo(workingDir) : undefined,
      parentSessionId: row.parentSessionId ?? undefined,
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
