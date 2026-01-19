/**
 * @fileoverview Session Manager
 *
 * Extracts session lifecycle management from EventStoreOrchestrator:
 * - Session creation, resumption, and termination
 * - Session listing and queries
 * - Fork operations
 *
 * Phase 5 of orchestrator refactoring.
 */
import * as path from 'path';
import * as os from 'os';
import {
  createLogger,
  EventStore,
  WorktreeCoordinator,
  SkillTracker,
  createSkillTracker,
  SubAgentTracker,
  createSubAgentTracker,
  RulesTracker,
  createRulesTracker,
  ContextLoader,
  TronAgent,
  type SessionId,
  type EventId,
  type EventType,
  type WorkingDirectory,
  type TronSessionEvent,
  type RulesLoadedPayload,
  type SkillTrackingEvent,
  type RulesTrackingEvent,
  type SubagentTrackingEvent,
  isPlanModeEnteredEvent,
  isPlanModeExitedEvent,
} from '@tron/core';
import { createSessionContext } from './session-context.js';
import { buildWorktreeInfo } from './worktree-ops.js';
import type {
  ActiveSession,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
} from './types.js';

const logger = createLogger('session-manager');

// =============================================================================
// Types
// =============================================================================

export interface SessionManagerConfig {
  /** EventStore instance */
  eventStore: EventStore;
  /** WorktreeCoordinator instance */
  worktreeCoordinator: WorktreeCoordinator;
  /** Default model for new sessions */
  defaultModel: string;
  /** Default provider for new sessions */
  defaultProvider: string;
  /** Maximum concurrent sessions */
  maxConcurrentSessions?: number;
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Set active session */
  setActiveSession: (sessionId: string, session: ActiveSession) => void;
  /** Delete active session */
  deleteActiveSession: (sessionId: string) => void;
  /** Get count of active sessions */
  getActiveSessionCount: () => number;
  /** Get all active sessions */
  getAllActiveSessions: () => IterableIterator<[string, ActiveSession]>;
  /** Create agent for a session */
  createAgentForSession: (
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string
  ) => Promise<TronAgent>;
  /** Emit event */
  emit: (event: string, data: unknown) => void;
  /** Estimate token count for text */
  estimateTokens: (text: string) => number;
  /** Check if browser service has session */
  hasBrowserSession?: (sessionId: string) => boolean;
  /** Close browser session */
  closeBrowserSession?: (sessionId: string) => Promise<void>;
}

// =============================================================================
// SessionManager Class
// =============================================================================

export class SessionManager {
  private config: SessionManagerConfig;
  private eventStore: EventStore;
  private worktreeCoordinator: WorktreeCoordinator;

  constructor(config: SessionManagerConfig) {
    this.config = config;
    this.eventStore = config.eventStore;
    this.worktreeCoordinator = config.worktreeCoordinator;
  }

  // ===========================================================================
  // Session Lifecycle
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<SessionInfo> {
    const maxSessions = this.config.maxConcurrentSessions ?? 10;
    if (this.config.getActiveSessionCount() >= maxSessions) {
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
    const agent = await this.config.createAgentForSession(
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
          mergedTokens: this.config.estimateTokens(loadedContext.merged),
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

    // Create SessionContext for modular state management
    const sessionContext = createSessionContext({
      sessionId,
      eventStore: this.eventStore,
      initialHeadEventId: rulesHeadEventId,
      model,
      workingDirectory: workingDir.path,
      workingDir,
    });

    const activeSession: ActiveSession = {
      sessionId,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model,
      // Parent session ID if this is a subagent (for event forwarding)
      parentSessionId: options.parentSessionId as SessionId | undefined,
      workingDir,
      // Initialize parallel event ID tracking for context manager messages
      messageEventIds: [],
      // Initialize empty skill tracker (new sessions have no skills)
      skillTracker: createSkillTracker(),
      // Initialize rules tracker with loaded rules
      rulesTracker,
      // SessionContext for modular state management
      sessionContext,
      // Initialize empty subagent tracker (new sessions have no subagents)
      subagentTracker: createSubAgentTracker(),
    };

    this.config.setActiveSession(sessionId, activeSession);

    this.config.emit('session_created', {
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
    const existing = this.config.getActiveSession(sessionId);
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
    const agent = await this.config.createAgentForSession(
      session.id,
      workingDir.path,
      session.latestModel,
      sessionState.systemPrompt // Restore system prompt from events
    );
    for (const msg of sessionState.messages) {
      // Convert event store messages to agent message format
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

    // Reconstruct trackers from event history
    // Use getAncestors to follow parent_id chain for forked sessions
    const events = session.headEventId
      ? await this.eventStore.getAncestors(session.headEventId)
      : [];
    const skillTracker = SkillTracker.fromEvents(events as SkillTrackingEvent[]);

    logger.info('Skill tracker reconstructed from events', {
      sessionId,
      addedSkillsCount: skillTracker.count,
    });

    const rulesTracker = RulesTracker.fromEvents(events as RulesTrackingEvent[]);

    logger.info('Rules tracker reconstructed from events', {
      sessionId,
      rulesFileCount: rulesTracker.getTotalFiles(),
    });

    const subagentTracker = SubAgentTracker.fromEvents(events as SubagentTrackingEvent[]);

    logger.info('Subagent tracker reconstructed from events', {
      sessionId,
      totalSubagents: subagentTracker.count,
      activeSubagents: subagentTracker.activeCount,
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

    // Create SessionContext for modular state management
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

    const activeSession: ActiveSession = {
      sessionId: session.id,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
      workingDirectory: workingDir.path,
      model: session.latestModel,
      workingDir,
      reasoningLevel,
      messageEventIds: sessionState.messageEventIds,
      skillTracker,
      rulesTracker,
      sessionContext,
      subagentTracker,
    };

    this.config.setActiveSession(sessionId, activeSession);

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
    const active = this.config.getActiveSession(sessionId);
    if (active?.isProcessing) {
      throw new Error('Cannot end session while processing');
    }

    // Check if session exists in EventStore before attempting to append events
    const session = await this.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      logger.info('Session not found in EventStore, cleaning up local state only', { sessionId });

      // Clean up any local state even if session doesn't exist in DB
      if (active) {
        this.config.deleteActiveSession(sessionId);
      }

      // Release worktree if any (may not exist, that's fine)
      try {
        await this.worktreeCoordinator.release(sessionId as SessionId, {
          mergeTo: options?.mergeTo,
          mergeStrategy: options?.mergeStrategy,
          commitMessage: options?.commitMessage,
        });
      } catch (err) {
        logger.debug('No worktree to release for session', { sessionId, err });
      }

      // Clean up browser session if it exists
      if (this.config.hasBrowserSession?.(sessionId)) {
        logger.debug('Closing browser session during session end', { sessionId });
        await this.config.closeBrowserSession?.(sessionId);
      }

      this.config.emit('session_ended', { sessionId, reason: 'not_found' });
      return;
    }

    // Append session.end event (linearized via SessionContext for active sessions)
    if (active?.sessionContext) {
      const event = await active.sessionContext.appendEvent('session.end', {
        reason: 'completed',
        timestamp: new Date().toISOString(),
      });
      if (event) {
        logger.debug('[LINEARIZE] session.end appended', {
          sessionId,
          eventId: event.id,
        });
      }
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
    if (this.config.hasBrowserSession?.(sessionId)) {
      logger.debug('Closing browser session during session end', { sessionId });
      await this.config.closeBrowserSession?.(sessionId);
    }

    await this.eventStore.endSession(sessionId as SessionId);
    this.config.deleteActiveSession(sessionId);

    this.config.emit('session_ended', { sessionId, reason: 'completed' });
    logger.info('Session ended', { sessionId });
  }

  // ===========================================================================
  // Session Queries
  // ===========================================================================

  async getSession(sessionId: string): Promise<SessionInfo | null> {
    const active = this.config.getActiveSession(sessionId);
    const isActive = !!active;
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
      const active = Array.from(this.config.getAllActiveSessions())
        .filter(([_, a]) => !options.workingDirectory || a.workingDirectory === options.workingDirectory)
        .slice(0, options.limit ?? 50);

      // Batch fetch sessions to prevent N+1 queries
      const sessionIds = active.map(([_, a]) => a.sessionId);
      const sessionsMap = await this.eventStore.getSessionsByIds(sessionIds);

      // Fetch message previews for all sessions
      const previews = await this.eventStore.getSessionMessagePreviews(sessionIds);

      const sessions: SessionInfo[] = [];
      for (const [_, a] of active) {
        const session = sessionsMap.get(a.sessionId);
        if (session) {
          sessions.push(this.sessionRowToInfo(session, true, a.workingDir, previews.get(a.sessionId)));
        }
      }
      return sessions;
    }

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
      const active = this.config.getActiveSession(row.id);
      return this.sessionRowToInfo(row, !!active, active?.workingDir, previews.get(row.id));
    });
  }

  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.config.getActiveSession(sessionId);
  }

  async wasSessionInterrupted(sessionId: string): Promise<boolean> {
    try {
      const events = await this.eventStore.getEventsBySession(sessionId as SessionId);

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
  // Fork Operations
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
    const parentActive = this.config.getActiveSession(sessionId);
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

    this.config.emit('session_forked', {
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
  // Cleanup
  // ===========================================================================

  async cleanupInactiveSessions(inactiveThresholdMs: number = 30 * 60 * 1000): Promise<void> {
    const now = Date.now();

    // Create snapshot to avoid modification during iteration
    const entries = Array.from(this.config.getAllActiveSessions());

    for (const [sessionId, active] of entries) {
      // Skip sessions that are currently processing
      if (active.sessionContext.isProcessing()) continue;

      const lastActivity = active.sessionContext.getLastActivity();
      const inactiveTime = now - lastActivity.getTime();
      if (inactiveTime > inactiveThresholdMs) {
        logger.info('Cleaning up inactive session', {
          sessionId,
          inactiveMinutes: Math.floor(inactiveTime / 60000),
        });

        try {
          await this.endSession(sessionId);
        } catch (err) {
          logger.error('Failed to end inactive session, removing from memory only', { sessionId, err });
          this.config.deleteActiveSession(sessionId);
        }
      }
    }
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

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

// =============================================================================
// Factory Function
// =============================================================================

export function createSessionManager(config: SessionManagerConfig): SessionManager {
  return new SessionManager(config);
}
