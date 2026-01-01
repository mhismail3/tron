/**
 * @fileoverview Session Orchestrator
 *
 * Manages multiple agent sessions, coordinating between the WebSocket
 * server and the agent runtime.
 */
import { EventEmitter } from 'events';
import {
  createLogger,
  TronAgent,
  SessionManager,
  SQLiteMemoryStore,
  HandoffManager,
  type Session,
  type AgentConfig,
  type TurnResult,
  type SessionManagerConfig,
  type ForkSessionResult,
  type RewindSessionResult,
  type Handoff,
  type CodeChange,
} from '@tron/core';

const logger = createLogger('orchestrator');

// =============================================================================
// Types
// =============================================================================

export interface OrchestratorConfig {
  /** Sessions directory */
  sessionsDir: string;
  /** Memory database path */
  memoryDbPath: string;
  /** Handoff database path (optional, defaults to same dir as memory) */
  handoffDbPath?: string;
  /** Default model */
  defaultModel: string;
  /** Default provider */
  defaultProvider: string;
  /** Max concurrent sessions */
  maxConcurrentSessions?: number;
}

export interface ActiveSession {
  session: Session;
  agent: TronAgent;
  isProcessing: boolean;
  lastActivity: Date;
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

export interface CreateHandoffOptions {
  sessionId: string;
  summary: string;
  codeChanges: CodeChange[];
  currentState: string;
  nextSteps: string[];
  blockers: string[];
  patterns: string[];
  metadata?: Record<string, unknown>;
}

// =============================================================================
// Session Orchestrator
// =============================================================================

export class SessionOrchestrator extends EventEmitter {
  private config: OrchestratorConfig;
  private activeSessions: Map<string, ActiveSession> = new Map();
  private sessionManager: SessionManager;
  private memoryStore: SQLiteMemoryStore;
  private handoffManager: HandoffManager;
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: OrchestratorConfig) {
    super();
    this.config = config;

    // Initialize session manager
    const sessionConfig: SessionManagerConfig = {
      sessionsDir: config.sessionsDir,
      defaultModel: config.defaultModel,
      defaultProvider: config.defaultProvider,
    };
    this.sessionManager = new SessionManager(sessionConfig);

    // Initialize memory store
    this.memoryStore = new SQLiteMemoryStore({ dbPath: config.memoryDbPath });

    // Initialize handoff manager
    const handoffDbPath = config.handoffDbPath ?? config.memoryDbPath.replace('.db', '-handoffs.db');
    this.handoffManager = new HandoffManager({ dbPath: handoffDbPath });

    // Forward session events
    this.sessionManager.on('session_created', (session) => {
      this.emit('session_created', session);
    });
    this.sessionManager.on('session_ended', (data) => {
      this.emit('session_ended', data);
    });
  }

  /**
   * Initialize the orchestrator
   */
  async initialize(): Promise<void> {
    // Initialize handoff manager
    await this.handoffManager.initialize();
    // SQLiteMemoryStore initializes in constructor, nothing else needed
    this.startCleanupTimer();
    logger.info('Orchestrator initialized');
  }

  /**
   * Shutdown the orchestrator
   */
  async shutdown(): Promise<void> {
    this.stopCleanupTimer();

    // End all active sessions
    for (const [sessionId, _active] of this.activeSessions.entries()) {
      try {
        await this.sessionManager.endSession(sessionId, 'aborted');
      } catch (error) {
        logger.error('Failed to end session during shutdown', { sessionId, error });
      }
    }
    this.activeSessions.clear();

    await this.memoryStore.close();
    await this.handoffManager.close();
    logger.info('Orchestrator shutdown complete');
  }

  // ===========================================================================
  // RpcContext Implementation
  // ===========================================================================

  getSessionManager(): SessionManager {
    return this.sessionManager;
  }

  getMemoryStore(): SQLiteMemoryStore {
    return this.memoryStore;
  }

  // ===========================================================================
  // Session Management
  // ===========================================================================

  /**
   * Create a new session
   */
  async createSession(options: {
    workingDirectory: string;
    model?: string;
    provider?: string;
    title?: string;
    tags?: string[];
    systemPrompt?: string;
  }): Promise<Session> {
    const maxSessions = this.config.maxConcurrentSessions ?? 10;
    if (this.activeSessions.size >= maxSessions) {
      throw new Error(`Maximum concurrent sessions (${maxSessions}) reached`);
    }

    const session = await this.sessionManager.createSession({
      workingDirectory: options.workingDirectory,
      model: options.model,
      provider: options.provider,
      title: options.title,
      tags: options.tags,
      systemPrompt: options.systemPrompt,
    });

    // Create agent for session
    const agent = await this.createAgentForSession(session);

    this.activeSessions.set(session.id, {
      session,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
    });

    logger.info('Session created', { sessionId: session.id });
    return session;
  }

  /**
   * Resume an existing session
   */
  async resumeSession(sessionId: string): Promise<Session> {
    // Check if already active
    const existing = this.activeSessions.get(sessionId);
    if (existing) {
      existing.lastActivity = new Date();
      return existing.session;
    }

    // Load from storage
    const session = await this.sessionManager.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Create agent
    const agent = await this.createAgentForSession(session);

    this.activeSessions.set(sessionId, {
      session,
      agent,
      isProcessing: false,
      lastActivity: new Date(),
    });

    logger.info('Session resumed', { sessionId });
    return session;
  }

  /**
   * End a session
   */
  async endSession(
    sessionId: string,
    reason: 'completed' | 'aborted' | 'error' | 'timeout' = 'completed'
  ): Promise<void> {
    const active = this.activeSessions.get(sessionId);
    if (active?.isProcessing) {
      throw new Error('Cannot end session while processing');
    }

    await this.sessionManager.endSession(sessionId, reason);
    this.activeSessions.delete(sessionId);

    logger.info('Session ended', { sessionId, reason });
  }

  /**
   * Get session by ID
   */
  async getSession(sessionId: string): Promise<Session | null> {
    const active = this.activeSessions.get(sessionId);
    if (active) {
      return active.session;
    }
    return this.sessionManager.getSession(sessionId);
  }

  /**
   * List sessions
   */
  async listSessions(options: {
    workingDirectory?: string;
    limit?: number;
    activeOnly?: boolean;
  }): Promise<Session[]> {
    if (options.activeOnly) {
      return Array.from(this.activeSessions.values())
        .filter(a => !options.workingDirectory || a.session.workingDirectory === options.workingDirectory)
        .slice(0, options.limit ?? 50)
        .map(a => a.session);
    }

    const summaries = await this.sessionManager.listSessions({
      workingDirectory: options.workingDirectory,
      limit: options.limit,
    });

    // Convert summaries to sessions
    const sessions: Session[] = [];
    for (const summary of summaries) {
      const session = await this.sessionManager.getSession(summary.id);
      if (session) {
        sessions.push(session);
      }
    }
    return sessions;
  }

  /**
   * Get active session info
   */
  getActiveSession(sessionId: string): ActiveSession | undefined {
    return this.activeSessions.get(sessionId);
  }

  // ===========================================================================
  // Session Fork & Rewind
  // ===========================================================================

  /**
   * Fork a session, creating a new session with copied messages
   *
   * This enables cross-interface workflows where a user can:
   * - Try a different approach from a specific point
   * - Create parallel work branches
   * - Experiment without losing original context
   */
  async forkSession(sessionId: string, fromIndex?: number): Promise<ForkSessionResult> {
    const result = await this.sessionManager.forkSession({
      sessionId,
      fromIndex,
    });

    logger.info('Session forked via orchestrator', {
      original: sessionId,
      forked: result.newSessionId,
      messageCount: result.messageCount,
    });

    return result;
  }

  /**
   * Rewind a session to a previous state
   *
   * This enables error recovery workflows where a user can:
   * - Undo recent messages after a bad approach
   * - Return to a known good state
   * - Continue with corrected instructions
   */
  async rewindSession(sessionId: string, toIndex: number): Promise<RewindSessionResult> {
    const result = await this.sessionManager.rewindSession({
      sessionId,
      toIndex,
    });

    // If this is an active session, refresh the cached session
    const active = this.activeSessions.get(sessionId);
    if (active) {
      const refreshed = await this.sessionManager.getSession(sessionId);
      if (refreshed) {
        active.session = refreshed;
      }
    }

    logger.info('Session rewound via orchestrator', {
      sessionId,
      toIndex,
      removedCount: result.removedCount,
    });

    return result;
  }

  // ===========================================================================
  // Handoff Operations (Episodic Memory)
  // ===========================================================================

  /**
   * Create a handoff record for a session
   *
   * Handoffs capture the state of a session for future context retrieval:
   * - Summary of what was accomplished
   * - Code changes made
   * - Current state and next steps
   * - Blockers and patterns learned
   */
  async createHandoff(options: CreateHandoffOptions): Promise<string> {
    const handoffId = await this.handoffManager.create({
      sessionId: options.sessionId,
      timestamp: new Date(),
      summary: options.summary,
      codeChanges: options.codeChanges,
      currentState: options.currentState,
      nextSteps: options.nextSteps,
      blockers: options.blockers,
      patterns: options.patterns,
      metadata: options.metadata,
    });

    logger.info('Handoff created', {
      handoffId,
      sessionId: options.sessionId,
    });

    return handoffId;
  }

  /**
   * List recent handoffs
   */
  async listHandoffs(limit: number = 5): Promise<Handoff[]> {
    return this.handoffManager.getRecent(limit);
  }

  /**
   * Get handoffs for a specific session
   */
  async getSessionHandoffs(sessionId: string): Promise<Handoff[]> {
    return this.handoffManager.getBySession(sessionId);
  }

  /**
   * Search handoffs by content
   */
  async searchHandoffs(query: string, limit: number = 10): Promise<Handoff[]> {
    const results = await this.handoffManager.search(query, limit);
    // Search returns HandoffSearchResult, but we need full Handoff objects
    // For now, return the search results as-is since they have the same core fields
    return results.map((r) => ({
      id: r.id,
      sessionId: r.sessionId,
      timestamp: r.timestamp,
      summary: r.summary,
      currentState: r.currentState,
      codeChanges: [],
      blockers: [],
      nextSteps: [],
      patterns: [],
    }));
  }

  /**
   * Get handoff manager for direct access
   */
  getHandoffManager(): HandoffManager {
    return this.handoffManager;
  }

  // ===========================================================================
  // Agent Operations
  // ===========================================================================

  /**
   * Run the agent for a session
   */
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
      // Add user message to session
      await this.sessionManager.addMessage(options.sessionId, {
        role: 'user',
        content: options.prompt,
      });

      // Run agent to completion
      const runResult = await active.agent.run(options.prompt);
      active.lastActivity = new Date();

      // Emit completion event
      this.emit('agent_turn', {
        type: 'turn_complete',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        data: runResult,
      });

      // Forward to callback
      if (options.onEvent) {
        options.onEvent({
          type: 'turn_complete',
          sessionId: options.sessionId,
          timestamp: new Date().toISOString(),
          data: runResult,
        });
      }

      // Update session in memory
      const updatedSession = await this.sessionManager.getSession(options.sessionId);
      if (updatedSession) {
        active.session = updatedSession;
      }

      // Return as array for compatibility
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

  /**
   * Cancel a running agent
   */
  async cancelAgent(sessionId: string): Promise<boolean> {
    const active = this.activeSessions.get(sessionId);
    if (!active || !active.isProcessing) {
      return false;
    }

    // Agent cancellation would need to be implemented in TronAgent
    // For now, just mark as not processing
    active.isProcessing = false;
    logger.info('Agent cancelled', { sessionId });
    return true;
  }

  // ===========================================================================
  // Memory Operations
  // ===========================================================================

  /**
   * Store a memory
   */
  async storeMemory(options: {
    sessionId?: string;
    workingDirectory: string;
    content: string;
    type: 'pattern' | 'decision' | 'lesson' | 'context' | 'preference';
    tags?: string[];
  }): Promise<string> {
    const entry = await this.memoryStore.addEntry({
      content: options.content,
      type: options.type,
      source: 'project',
      tags: options.tags,
      metadata: {
        workingDirectory: options.workingDirectory,
        sessionId: options.sessionId,
      },
    });
    return entry.id;
  }

  /**
   * Search memories
   */
  async searchMemory(options: {
    query: string;
    workingDirectory?: string;
    type?: 'pattern' | 'decision' | 'lesson' | 'context' | 'preference';
    limit?: number;
  }): Promise<Array<{ id: string; content: string; score: number }>> {
    const results = await this.memoryStore.searchEntries({
      searchText: options.query,
      type: options.type,
      limit: options.limit ?? 10,
      projectPath: options.workingDirectory,
    });

    return results.entries.map((entry) => ({
      id: entry.id,
      content: entry.content,
      score: 1.0, // Default score as interface doesn't have scores
    }));
  }

  // ===========================================================================
  // Health & Stats
  // ===========================================================================

  /**
   * Get orchestrator health status
   */
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
  // Private Methods
  // ===========================================================================

  private async createAgentForSession(session: Session): Promise<TronAgent> {
    // Get API key from environment
    const apiKey = process.env.ANTHROPIC_API_KEY ?? '';

    const agentConfig: AgentConfig = {
      provider: {
        model: session.model,
        auth: {
          type: 'api_key' as const,
          apiKey,
        },
      },
      tools: [], // Tools would be registered separately
      systemPrompt: session.systemPrompt,
      maxTurns: 50,
    };

    return new TronAgent(agentConfig, {
      sessionId: session.id,
      workingDirectory: session.workingDirectory,
    });
  }

  private startCleanupTimer(): void {
    // Clean up inactive sessions every 5 minutes
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
      if (active.isProcessing) {
        continue;
      }

      const inactiveTime = now - active.lastActivity.getTime();
      if (inactiveTime > inactiveThreshold) {
        logger.info('Cleaning up inactive session', { sessionId, inactiveMinutes: Math.floor(inactiveTime / 60000) });
        this.activeSessions.delete(sessionId);
      }
    }
  }
}
