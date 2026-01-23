/**
 * @fileoverview EventStore-backed TUI Session
 *
 * A TUI session implementation that uses the EventStore for all persistence.
 * This provides:
 * - Full event sourcing with immutable event log
 * - Tree structure for fork operations
 * - Direct database access (local-first performance)
 * - State reconstruction from events at any point in time
 *
 * @example
 * ```typescript
 * const eventStore = new EventStore('~/.tron/db/prod.db');
 * await eventStore.initialize();
 *
 * const session = new EventStoreTuiSession({
 *   workingDirectory: '/path/to/project',
 *   tronDir: '~/.tron',
 *   model: 'claude-sonnet-4-20250514',
 *   provider: 'anthropic',
 *   eventStore,
 * });
 *
 * const { sessionId, systemPrompt } = await session.initialize();
 * await session.addMessage({ role: 'user', content: 'Hello' });
 * const forkResult = await session.fork();
 * await session.end();
 * ```
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import {
  EventStore,
  ContextLoader,
  ContextAudit,
  createContextAudit,
  ContextCompactor,
  createContextCompactor,
  type Message,
  type TokenUsage,
  type LoadedContext,
  type ContextAuditData,
  type CompactResult,
  type SessionId,
  type EventId,
  type TronSessionEvent,
  type EventMessage,
  type EventSearchResult,
} from '@tron/agent';

/**
 * Handoff record for session context continuity
 * Previously from memory module, now defined locally
 */
export interface Handoff {
  id?: string;
  sessionId: string;
  timestamp: Date;
  summary: string;
  codeChanges: string[];
  currentState: string;
  blockers: string[];
  nextSteps: string[];
  patterns: string[];
  metadata?: Record<string, unknown>;
}

// Version for event metadata
const VERSION = '0.1.0';

// =============================================================================
// Types
// =============================================================================

export type EventStoreTuiSessionState = 'uninitialized' | 'ready' | 'ended';

export interface EventStoreTuiSessionConfig {
  /** Working directory for the session (project root) */
  workingDirectory: string;
  /** Global Tron directory (~/.tron) */
  tronDir: string;
  /** Model to use */
  model: string;
  /** Provider name */
  provider: string;
  /** EventStore instance (required) */
  eventStore: EventStore;
  /** Resume existing session by ID */
  sessionId?: string;
  /** Minimum messages for handoff/summary creation (default: 2) */
  minMessagesForHandoff?: number;
  /** Ephemeral mode - no persistence (default: false) */
  ephemeral?: boolean;
  /** Maximum tokens before compaction (default: 25000) */
  compactionMaxTokens?: number;
  /** Threshold ratio to trigger compaction (default: 0.85) */
  compactionThreshold?: number;
  /** Target tokens after compaction (default: 10000) */
  compactionTargetTokens?: number;
}

export interface EventStoreCompactionConfig {
  maxTokens: number;
  threshold: number;
  targetTokens: number;
}

export interface EventStoreInitializeResult {
  /** Session ID */
  sessionId: string;
  /** Loaded context from AGENTS.md files */
  context?: LoadedContext;
  /** Recent handoffs/session summaries for context */
  handoffs?: Handoff[];
  /** System prompt with all context */
  systemPrompt: string;
  /** Context audit for traceability */
  audit: ContextAuditData;
}

export interface EventStoreEndResult {
  /** Session ID */
  sessionId: string;
  /** Whether a summary/handoff was created */
  handoffCreated: boolean;
  /** Total message count */
  messageCount: number;
  /** Total token usage */
  tokenUsage: TokenUsage;
}

export interface ForkResult {
  /** New session ID */
  newSessionId: string;
  /** Root event ID of new session */
  rootEventId: string;
  /** Event ID the fork was created from */
  forkedFromEventId: string;
  /** Session ID the fork was created from */
  forkedFromSessionId: string;
}

export interface ToolCallRecord {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
}

export interface ToolResultRecord {
  toolCallId: string;
  result: string;
  isError: boolean;
}

export interface TreeVisualization {
  root: TreeNode;
  branchPoints: string[];
}

export interface TreeNode {
  id: string;
  parentId: string | null;
  type: string;
  timestamp: string;
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
}

// =============================================================================
// EventStoreTuiSession Implementation
// =============================================================================

export class EventStoreTuiSession {
  private config: EventStoreTuiSessionConfig;
  private state: EventStoreTuiSessionState = 'uninitialized';
  private sessionId: SessionId | null = null;
  private eventStore: EventStore;

  // Context loading (still uses files)
  private contextLoader: ContextLoader | null = null;
  private loadedContext: LoadedContext | null = null;

  // Context audit for traceability
  private contextAudit: ContextAudit | null = null;

  // Compaction
  private compactor: ContextCompactor;

  // In-memory cache for ephemeral mode and performance
  private cachedMessages: Message[] = [];
  private cachedTokenUsage: TokenUsage = { inputTokens: 0, outputTokens: 0 };

  constructor(config: EventStoreTuiSessionConfig) {
    this.config = {
      minMessagesForHandoff: 2,
      ephemeral: false,
      compactionMaxTokens: 25000,
      compactionThreshold: 0.85,
      compactionTargetTokens: 10000,
      ...config,
    };

    this.eventStore = config.eventStore;

    // Initialize compactor
    this.compactor = createContextCompactor({
      maxTokens: this.config.compactionMaxTokens,
      compactionThreshold: this.config.compactionThreshold,
      targetTokens: this.config.compactionTargetTokens,
    });
  }

  /**
   * Check if session is in ephemeral mode (no persistence)
   */
  isEphemeral(): boolean {
    return this.config.ephemeral === true;
  }

  // ===========================================================================
  // Lifecycle Methods
  // ===========================================================================

  /**
   * Initialize the session
   */
  async initialize(): Promise<EventStoreInitializeResult> {
    // Create context audit for traceability
    this.contextAudit = createContextAudit();

    // Ensure directories exist
    await this.ensureDirectories();

    // Initialize context loader
    this.contextLoader = new ContextLoader({
      userHome: process.env.HOME ?? '',
      projectRoot: this.config.workingDirectory,
      contextFileNames: ['AGENTS.md', 'CLAUDE.md'],
      agentDir: '.tron',
    });

    // Load context from AGENTS.md files
    this.loadedContext = await this.loadContext();

    // Record context files in audit
    if (this.loadedContext?.files) {
      for (const file of this.loadedContext.files) {
        this.contextAudit.addContextFile({
          path: file.path,
          type: file.level,
          content: file.content,
        });
      }
    }

    // Resume or create session
    if (this.config.sessionId) {
      await this.resumeSession(this.config.sessionId);
    } else {
      await this.createNewSession();
    }

    // Record session info in audit
    this.contextAudit.setSession({
      id: this.sessionId!,
      type: this.config.sessionId ? 'resume' : 'new',
      startedAt: new Date(),
      workingDirectory: this.config.workingDirectory,
      model: this.config.model,
    });

    // Update state
    this.state = 'ready';

    // Build system prompt
    const systemPrompt = this.buildSystemPrompt();
    this.recordSystemPromptInAudit(systemPrompt);

    // Load recent handoffs/session summaries for context
    const handoffs = await this.loadRecentHandoffs();

    return {
      sessionId: this.sessionId!,
      context: this.loadedContext ?? undefined,
      handoffs: handoffs.length > 0 ? handoffs : undefined,
      systemPrompt,
      audit: this.contextAudit.getData(),
    };
  }

  /**
   * End the session
   */
  async end(): Promise<EventStoreEndResult> {
    if (this.state === 'ended') {
      return {
        sessionId: this.sessionId!,
        handoffCreated: false,
        messageCount: this.cachedMessages.length,
        tokenUsage: this.cachedTokenUsage,
      };
    }

    const messageCount = this.cachedMessages.length;
    let handoffCreated = false;

    // Skip persistence in ephemeral mode
    if (!this.isEphemeral() && this.sessionId) {
      // Create summary if enough messages
      const summary = messageCount >= (this.config.minMessagesForHandoff ?? 2)
        ? this.generateSummary()
        : undefined;

      // Append session.end event
      await this.eventStore.append({
        sessionId: this.sessionId,
        type: 'session.end',
        payload: {
          reason: 'completed',
          summary,
          messageCount,
          tokenUsage: this.cachedTokenUsage,
          workingDirectory: this.config.workingDirectory,
          timestamp: new Date().toISOString(),
        },
      });

      // Mark session as ended
      await this.eventStore.endSession(this.sessionId);

      handoffCreated = !!summary;
    }

    this.state = 'ended';

    return {
      sessionId: this.sessionId!,
      handoffCreated,
      messageCount,
      tokenUsage: this.cachedTokenUsage,
    };
  }

  // ===========================================================================
  // Message Methods
  // ===========================================================================

  /**
   * Add a message to the session
   */
  async addMessage(message: Message, tokenUsage?: TokenUsage): Promise<void> {
    this.ensureReady();

    // Track in cache
    this.cachedMessages.push(message);

    // Track token usage
    if (tokenUsage) {
      this.cachedTokenUsage.inputTokens += tokenUsage.inputTokens;
      this.cachedTokenUsage.outputTokens += tokenUsage.outputTokens;
    }

    // Skip persistence in ephemeral mode
    if (this.isEphemeral()) {
      return;
    }

    const eventType = message.role === 'user' ? 'message.user' : 'message.assistant';

    await this.eventStore.append({
      sessionId: this.sessionId!,
      type: eventType,
      payload: {
        content: message.content,
        role: message.role,
        timestamp: new Date().toISOString(),
        // Include tokenUsage in payload for state reconstruction
        ...(tokenUsage && { tokenUsage }),
      },
    });
  }

  /**
   * Get all messages from the session
   */
  async getMessages(): Promise<Message[]> {
    if (this.isEphemeral() || !this.sessionId) {
      return [...this.cachedMessages];
    }

    const eventMessages = await this.eventStore.getMessagesAtHead(this.sessionId);
    return eventMessages.map(em => this.eventMessageToMessage(em));
  }

  // ===========================================================================
  // Tool Recording
  // ===========================================================================

  /**
   * Record a tool call
   */
  async recordToolCall(call: ToolCallRecord): Promise<void> {
    this.ensureReady();

    if (this.isEphemeral()) {
      return;
    }

    await this.eventStore.append({
      sessionId: this.sessionId!,
      type: 'tool.call',
      payload: {
        toolCallId: call.toolCallId,
        toolName: call.toolName,
        arguments: call.arguments,
        timestamp: new Date().toISOString(),
      },
    });
  }

  /**
   * Record a tool result
   */
  async recordToolResult(result: ToolResultRecord): Promise<void> {
    this.ensureReady();

    if (this.isEphemeral()) {
      return;
    }

    await this.eventStore.append({
      sessionId: this.sessionId!,
      type: 'tool.result',
      payload: {
        toolCallId: result.toolCallId,
        result: result.result,
        isError: result.isError,
        timestamp: new Date().toISOString(),
      },
    });
  }

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  /**
   * Get full session state
   */
  async getSessionState(): Promise<{
    messages: Message[];
    tokenUsage: TokenUsage;
    messageCount: number;
  }> {
    if (this.isEphemeral() || !this.sessionId) {
      return {
        messages: [...this.cachedMessages],
        tokenUsage: { ...this.cachedTokenUsage },
        messageCount: this.cachedMessages.length,
      };
    }

    const state = await this.eventStore.getStateAtHead(this.sessionId);
    const messages = state.messages.map(em => this.eventMessageToMessage(em));

    return {
      messages,
      tokenUsage: state.tokenUsage,
      messageCount: messages.length,
    };
  }

  /**
   * Get state at specific event (point-in-time)
   */
  async getStateAt(eventId: EventId): Promise<{
    messages: Message[];
    tokenUsage: TokenUsage;
  }> {
    const state = await this.eventStore.getStateAt(eventId);
    const messages = state.messages.map(em => this.eventMessageToMessage(em));

    return {
      messages,
      tokenUsage: state.tokenUsage,
    };
  }

  /**
   * Get token usage
   */
  getTokenUsage(): TokenUsage {
    return { ...this.cachedTokenUsage };
  }

  // ===========================================================================
  // Fork Operations
  // ===========================================================================

  /**
   * Fork the session (create new branch)
   */
  async fork(options?: { fromEventId?: EventId; name?: string }): Promise<ForkResult> {
    this.ensureReady();

    if (!this.sessionId) {
      throw new Error('No session to fork');
    }

    // Get current head if no specific event provided
    let forkFromEventId = options?.fromEventId;
    if (!forkFromEventId) {
      const session = await this.eventStore.getSession(this.sessionId);
      forkFromEventId = session?.headEventId ?? undefined;
    }

    if (!forkFromEventId) {
      throw new Error('Cannot determine fork point');
    }

    const result = await this.eventStore.fork(forkFromEventId, {
      name: options?.name,
    });

    return {
      newSessionId: result.session.id,
      rootEventId: result.rootEvent.id,
      forkedFromEventId: forkFromEventId,
      forkedFromSessionId: this.sessionId,
    };
  }

  // ===========================================================================
  // Compaction
  // ===========================================================================

  /**
   * Check if compaction is needed
   */
  needsCompaction(): boolean {
    return this.compactor.shouldCompact(this.cachedMessages);
  }

  /**
   * Get compaction configuration
   */
  getCompactionConfig(): EventStoreCompactionConfig {
    return {
      maxTokens: this.config.compactionMaxTokens ?? 25000,
      threshold: this.config.compactionThreshold ?? 0.85,
      targetTokens: this.config.compactionTargetTokens ?? 10000,
    };
  }

  /**
   * Perform compaction
   */
  async compact(): Promise<CompactResult> {
    if (!this.needsCompaction()) {
      return {
        compacted: false,
        messages: this.cachedMessages,
        summary: '',
        originalTokens: this.compactor.estimateTokens(this.cachedMessages),
        newTokens: this.compactor.estimateTokens(this.cachedMessages),
      };
    }

    const result = await this.compactor.compact(this.cachedMessages);

    if (result.compacted) {
      // Update cached messages
      this.cachedMessages = result.messages;

      // Record compaction events
      if (!this.isEphemeral() && this.sessionId) {
        await this.eventStore.append({
          sessionId: this.sessionId,
          type: 'compact.boundary',
          payload: {
            originalTokens: result.originalTokens,
            timestamp: new Date().toISOString(),
          },
        });

        await this.eventStore.append({
          sessionId: this.sessionId,
          type: 'compact.summary',
          payload: {
            summary: result.summary,
            newTokens: result.newTokens,
            timestamp: new Date().toISOString(),
          },
        });
      }
    }

    return result;
  }

  // ===========================================================================
  // Search
  // ===========================================================================

  /**
   * Search messages in this session
   */
  async searchMessages(query: string): Promise<Array<{ content: string; type: string }>> {
    if (!this.sessionId) {
      return [];
    }

    const results = await this.eventStore.search(query, {
      sessionId: this.sessionId,
      types: ['message.user', 'message.assistant'],
    });

    // SearchResult has eventId, snippet, type - not event object
    return results.map(r => ({
      content: r.snippet,
      type: r.type,
    }));
  }

  /**
   * Search across all sessions in workspace
   */
  async searchWorkspace(query: string): Promise<EventSearchResult[]> {
    // Get workspace ID from session
    if (!this.sessionId) {
      return [];
    }

    const session = await this.eventStore.getSession(this.sessionId);
    if (!session?.workspaceId) {
      return [];
    }

    return this.eventStore.search(query, {
      workspaceId: session.workspaceId,
    });
  }

  // ===========================================================================
  // Event History
  // ===========================================================================

  /**
   * Get recent events
   */
  async getRecentEvents(limit: number): Promise<TronSessionEvent[]> {
    if (!this.sessionId) {
      return [];
    }

    const events = await this.eventStore.getEventsBySession(this.sessionId);
    return events.slice(-limit);
  }

  /**
   * Get ancestors (full history to root)
   */
  async getAncestors(): Promise<TronSessionEvent[]> {
    if (!this.sessionId) {
      return [];
    }

    const session = await this.eventStore.getSession(this.sessionId);
    if (!session?.headEventId) {
      return [];
    }

    return this.eventStore.getAncestors(session.headEventId);
  }

  /**
   * Get tree visualization data
   */
  async getTreeVisualization(): Promise<TreeVisualization> {
    if (!this.sessionId) {
      return { root: this.createEmptyTreeNode(), branchPoints: [] };
    }

    const session = await this.eventStore.getSession(this.sessionId);
    if (!session?.rootEventId) {
      return { root: this.createEmptyTreeNode(), branchPoints: [] };
    }

    const rootEvent = await this.eventStore.getEvent(session.rootEventId);
    if (!rootEvent) {
      return { root: this.createEmptyTreeNode(), branchPoints: [] };
    }

    // Find branch points (events with multiple children)
    const branchPoints: string[] = [];
    const events = await this.eventStore.getEventsBySession(this.sessionId);

    for (const event of events) {
      const children = await this.eventStore.getChildren(event.id);
      if (children.length > 1) {
        branchPoints.push(event.id);
      }
    }

    return {
      root: this.eventToTreeNode(rootEvent, session.headEventId === rootEvent.id, 0),
      branchPoints,
    };
  }

  // ===========================================================================
  // Context Methods
  // ===========================================================================

  /**
   * Build the system prompt.
   * Note: Rules content is now handled by agent.setRulesContent() for consistent
   * caching behavior across TUI, server, and iOS clients.
   * @deprecated Use agent.setRulesContent(getRulesContent()) instead
   */
  buildSystemPrompt(): string {
    // Rules are now injected via agent.setRulesContent() for proper cache_control handling
    // This method is kept for backwards compatibility but returns empty
    return '';
  }

  /**
   * Get rules content from loaded context (for agent.setRulesContent())
   */
  getRulesContent(): string | undefined {
    return this.loadedContext?.merged;
  }

  // ===========================================================================
  // State & Getters
  // ===========================================================================

  /**
   * Get current session state
   */
  getState(): EventStoreTuiSessionState {
    return this.state;
  }

  /**
   * Get session ID
   */
  getSessionId(): SessionId {
    if (!this.sessionId) {
      throw new Error('Session not initialized');
    }
    return this.sessionId;
  }

  /**
   * Get current message count
   */
  getMessageCount(): number {
    return this.cachedMessages.length;
  }

  /**
   * Get current token estimate for tracked messages
   */
  getTokenEstimate(): number {
    return this.compactor.estimateTokens(this.cachedMessages);
  }

  /**
   * Set the total token usage (cumulative from agent)
   */
  setTokenUsage(usage: TokenUsage): void {
    this.cachedTokenUsage = { ...usage };
  }

  /**
   * Get the context audit as markdown (for display)
   */
  getContextAuditMarkdown(): string {
    return this.contextAudit?.toMarkdown() ?? 'No context audit available';
  }

  /**
   * Get a compact audit summary
   */
  getContextAuditSummary(): string {
    return this.contextAudit?.toSummary() ?? 'No context audit available';
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private ensureReady(): void {
    if (this.state === 'uninitialized') {
      throw new Error('Session not initialized');
    }
    if (this.state === 'ended') {
      throw new Error('Session has ended');
    }
  }

  private async ensureDirectories(): Promise<void> {
    const dirs = [
      this.config.tronDir,
      path.join(this.config.tronDir, 'events'),
    ];

    for (const dir of dirs) {
      try {
        await fs.mkdir(dir, { recursive: true });
      } catch (error) {
        const err = error as NodeJS.ErrnoException;
        if (err.code !== 'EEXIST') {
          throw error;
        }
      }
    }
  }

  private async createNewSession(): Promise<void> {
    if (this.isEphemeral()) {
      // Generate ID locally without persisting
      this.sessionId = `sess_${crypto.randomUUID().slice(0, 12)}` as SessionId;
      return;
    }

    const result = await this.eventStore.createSession({
      workspacePath: this.config.workingDirectory,
      workingDirectory: this.config.workingDirectory,
      model: this.config.model,
      provider: this.config.provider,
      metadata: {
        clientType: 'tui',
        version: VERSION,
      },
    });

    this.sessionId = result.session.id;

    // Load initial state
    await this.reloadCachedState();
  }

  private async resumeSession(sessionId: string): Promise<void> {
    this.sessionId = sessionId as SessionId;

    if (this.isEphemeral()) {
      return;
    }

    // Load session state
    await this.reloadCachedState();
  }

  private async reloadCachedState(): Promise<void> {
    if (!this.sessionId) {
      return;
    }

    const state = await this.eventStore.getStateAtHead(this.sessionId);

    // Convert event messages to regular messages
    this.cachedMessages = state.messages.map(em => this.eventMessageToMessage(em));
    this.cachedTokenUsage = state.tokenUsage;
  }

  private async loadContext(): Promise<LoadedContext | null> {
    try {
      return await this.contextLoader!.load(this.config.workingDirectory);
    } catch {
      return null;
    }
  }

  private async loadRecentHandoffs(): Promise<Handoff[]> {
    // Load from recent session.end events with summaries
    if (!this.sessionId) {
      return [];
    }

    try {
      const session = await this.eventStore.getSession(this.sessionId);
      if (!session?.workspaceId) {
        return [];
      }

      // Search for session.end events with summaries
      const results = await this.eventStore.search('summary', {
        workspaceId: session.workspaceId,
        types: ['session.end'],
        limit: 3,
      });

      // SearchResult has eventId, sessionId, type, timestamp, snippet, score
      // We need to transform these into Handoff objects
      return results.map(r => ({
        id: r.eventId,
        sessionId: r.sessionId,
        timestamp: new Date(r.timestamp),
        summary: r.snippet || '',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
        metadata: {},
      }));
    } catch {
      return [];
    }
  }

  private eventMessageToMessage(em: EventMessage): Message {
    if (em.role === 'user') {
      return {
        role: 'user',
        content: typeof em.content === 'string' ? em.content : JSON.stringify(em.content),
      };
    } else {
      // EventMessage content from events needs to be cast to AssistantContent[]
      const content = Array.isArray(em.content)
        ? em.content as Array<{ type: string; text?: string }>
        : [{ type: 'text' as const, text: String(em.content) }];
      return {
        role: 'assistant',
        content,
      } as Message;
    }
  }

  private generateSummary(): string {
    const parts: string[] = [];
    parts.push(`${this.cachedMessages.length} messages exchanged`);
    return parts.join('. ') || 'Session completed';
  }

  private recordSystemPromptInAudit(systemPrompt: string): void {
    if (!this.contextAudit) return;

    const sections: Array<{ name: string; content: string; source: string }> = [];

    if (this.loadedContext?.merged) {
      sections.push({
        name: 'Project Context',
        content: this.loadedContext.merged,
        source: 'AGENTS.md hierarchy',
      });
    }

    this.contextAudit.setSystemPrompt({
      content: systemPrompt,
      sections,
    });
  }

  private eventToTreeNode(event: TronSessionEvent, isHead: boolean, depth: number): TreeNode {
    return {
      id: event.id,
      parentId: event.parentId ?? null,
      type: event.type,
      timestamp: event.timestamp,
      summary: this.getEventSummary(event),
      hasChildren: false, // Would need to check
      childCount: 0,
      depth,
      isBranchPoint: false,
      isHead,
    };
  }

  private createEmptyTreeNode(): TreeNode {
    return {
      id: '',
      parentId: null,
      type: 'unknown',
      timestamp: '',
      summary: '',
      hasChildren: false,
      childCount: 0,
      depth: 0,
      isBranchPoint: false,
      isHead: false,
    };
  }

  private getEventSummary(event: TronSessionEvent): string {
    switch (event.type) {
      case 'session.start':
        return 'Session started';
      case 'session.end':
        return event.payload.summary || 'Session ended';
      case 'message.user':
        return typeof event.payload.content === 'string'
          ? event.payload.content.slice(0, 50)
          : 'User message';
      case 'message.assistant':
        return 'Assistant response';
      case 'tool.call':
        return `Tool: ${event.payload.name}`;
      case 'tool.result':
        return `Tool result (${event.payload.isError ? 'error' : 'success'})`;
      default:
        return event.type;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createEventStoreTuiSession(config: EventStoreTuiSessionConfig): EventStoreTuiSession {
  return new EventStoreTuiSession(config);
}
