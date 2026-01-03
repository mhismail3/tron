/**
 * @fileoverview TUI Session Orchestrator
 *
 * Unified session management that wires together:
 * - Context loading (AGENTS.md hierarchy)
 * - Session persistence (JSONL files)
 * - Memory/handoff management (SQLite with FTS5)
 * - Ledger management (continuity state)
 *
 * This is the single source of truth for TUI session state,
 * providing a clean interface for the React components.
 *
 * @example
 * ```typescript
 * const session = new TuiSession({
 *   workingDirectory: '/path/to/project',
 *   tronDir: '~/.tron',
 *   model: 'claude-sonnet-4-20250514',
 *   provider: 'anthropic',
 * });
 *
 * const { context, ledger, handoffs } = await session.initialize();
 * await session.addMessage({ role: 'user', content: 'Hello' });
 * await session.end();
 * ```
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import {
  SessionManager,
  HandoffManager,
  LedgerManager,
  ContextLoader,
  ContextAudit,
  createContextAudit,
  ContextCompactor,
  createContextCompactor,
  type Message,
  type TokenUsage,
  type Ledger,
  type Handoff,
  type LoadedContext,
  type HandoffSearchResult,
  type ContextAuditData,
  type CompactResult,
} from '@tron/core';

// =============================================================================
// Types
// =============================================================================

export type TuiSessionState = 'uninitialized' | 'ready' | 'ended';

export interface TuiSessionConfig {
  /** Working directory for the session (project root) */
  workingDirectory: string;
  /** Global Tron directory (~/.tron) */
  tronDir: string;
  /** Model to use */
  model: string;
  /** Provider name */
  provider: string;
  /** Minimum messages for handoff creation (default: 2) */
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

export interface CompactionConfig {
  maxTokens: number;
  threshold: number;
  targetTokens: number;
}

export interface InitializeResult {
  /** Session ID */
  sessionId: string;
  /** Loaded context from AGENTS.md files */
  context?: LoadedContext;
  /** Current ledger state */
  ledger?: Ledger;
  /** Recent handoffs for context */
  handoffs?: Handoff[];
  /** System prompt with all context */
  systemPrompt: string;
  /** Context audit for traceability */
  contextAudit: ContextAuditData;
}

export interface EndResult {
  /** Whether a handoff was created */
  handoffCreated: boolean;
  /** Handoff ID if created */
  handoffId?: string;
  /** Total message count */
  messageCount: number;
  /** Total token usage */
  tokenUsage: TokenUsage;
}

// =============================================================================
// TuiSession Implementation
// =============================================================================

export class TuiSession {
  private config: TuiSessionConfig;
  private state: TuiSessionState = 'uninitialized';
  private sessionId: string = '';

  // Managers
  private sessionManager: SessionManager | null = null;
  private handoffManager: HandoffManager | null = null;
  private ledgerManager: LedgerManager | null = null;
  private contextLoader: ContextLoader | null = null;

  // Cached data
  private loadedContext: LoadedContext | null = null;
  private loadedLedger: Ledger | null = null;
  private recentHandoffs: Handoff[] = [];

  // Context audit for traceability
  private contextAudit: ContextAudit | null = null;

  // Session stats
  private messageCount = 0;
  private totalTokenUsage: TokenUsage = { inputTokens: 0, outputTokens: 0 };

  // Compaction
  private compactor: ContextCompactor;
  private messages: Message[] = [];

  constructor(config: TuiSessionConfig) {
    this.config = {
      minMessagesForHandoff: 2,
      ephemeral: false,
      compactionMaxTokens: 25000,
      compactionThreshold: 0.85,
      compactionTargetTokens: 10000,
      ...config,
    };

    // Initialize compactor with config
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
   * Initialize the session and all managers
   */
  async initialize(): Promise<InitializeResult> {
    // Create context audit for traceability
    this.contextAudit = createContextAudit();

    // Ensure directories exist
    await this.ensureDirectories();

    // Initialize managers
    await this.initializeManagers();

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

    // Load ledger state
    this.loadedLedger = await this.loadLedger();

    // Record ledger in audit
    this.contextAudit.setLedger(this.loadedLedger);

    // Load recent handoffs
    this.recentHandoffs = await this.loadRecentHandoffs();

    // Record handoffs in audit
    for (const handoff of this.recentHandoffs) {
      if (handoff.id) {
        this.contextAudit.addHandoff({
          id: handoff.id,
          sessionId: handoff.sessionId,
          summary: handoff.summary,
          timestamp: handoff.timestamp,
        });
      }
    }

    // Create session - skip persistence in ephemeral mode
    if (this.isEphemeral()) {
      // Generate ID locally without persisting
      this.sessionId = `sess_${crypto.randomUUID().slice(0, 12)}`;
    } else {
      // Create session in session manager (uses its own ID generation)
      const session = await this.sessionManager!.createSession({
        workingDirectory: this.config.workingDirectory,
        model: this.config.model,
        provider: this.config.provider,
      });
      this.sessionId = session.id;
    }

    // Record session info in audit
    this.contextAudit.setSession({
      id: this.sessionId,
      type: 'new',
      startedAt: new Date(),
      workingDirectory: this.config.workingDirectory,
      model: this.config.model,
      provider: this.config.provider,
    });

    // Update state
    this.state = 'ready';

    // Build system prompt and record in audit
    const systemPrompt = this.buildSystemPrompt();
    this.recordSystemPromptInAudit(systemPrompt);

    return {
      sessionId: this.sessionId,
      context: this.loadedContext ?? undefined,
      ledger: this.loadedLedger ?? undefined,
      handoffs: this.recentHandoffs.length > 0 ? this.recentHandoffs : undefined,
      systemPrompt,
      contextAudit: this.contextAudit.getData(),
    };
  }

  /**
   * End the session, creating handoff if appropriate
   */
  async end(): Promise<EndResult> {
    if (this.state === 'ended') {
      return {
        handoffCreated: false,
        messageCount: this.messageCount,
        tokenUsage: this.totalTokenUsage,
      };
    }

    let handoffCreated = false;
    let handoffId: string | undefined;

    // Skip persistence in ephemeral mode
    if (!this.isEphemeral()) {
      // Create handoff if enough messages
      if (this.messageCount >= (this.config.minMessagesForHandoff ?? 2)) {
        try {
          handoffId = await this.createHandoff();
          handoffCreated = true;
        } catch (error) {
          // Log but don't fail session end
          console.error('Failed to create handoff:', error);
        }
      }

      // Write session_end entry
      if (this.sessionManager && this.sessionId) {
        await this.sessionManager.endSession(this.sessionId, 'completed');
      }
    }

    this.state = 'ended';

    return {
      handoffCreated,
      handoffId,
      messageCount: this.messageCount,
      tokenUsage: this.totalTokenUsage,
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

    // Track message for compaction
    this.messages.push(message);

    // Skip persistence in ephemeral mode
    if (!this.isEphemeral()) {
      await this.sessionManager!.addMessage(this.sessionId, message, tokenUsage);
    }
    this.messageCount++;

    if (tokenUsage) {
      this.totalTokenUsage.inputTokens += tokenUsage.inputTokens;
      this.totalTokenUsage.outputTokens += tokenUsage.outputTokens;
    }
  }

  /**
   * Get current message count
   */
  getMessageCount(): number {
    return this.messageCount;
  }

  /**
   * Get all tracked messages
   */
  getMessages(): Message[] {
    return [...this.messages];
  }

  /**
   * Set the total token usage (cumulative from agent)
   * Use this instead of adding per-message to avoid multiplication bugs
   */
  setTokenUsage(usage: TokenUsage): void {
    this.totalTokenUsage = { ...usage };
  }

  // ===========================================================================
  // Compaction Methods
  // ===========================================================================

  /**
   * Get compaction configuration
   */
  getCompactionConfig(): CompactionConfig {
    return {
      maxTokens: this.config.compactionMaxTokens ?? 25000,
      threshold: this.config.compactionThreshold ?? 0.85,
      targetTokens: this.config.compactionTargetTokens ?? 10000,
    };
  }

  /**
   * Get current token estimate for tracked messages
   */
  getTokenEstimate(): number {
    return this.compactor.estimateTokens(this.messages);
  }

  /**
   * Check if compaction is needed based on current message size
   */
  needsCompaction(): boolean {
    return this.compactor.shouldCompact(this.messages);
  }

  /**
   * Compact messages if needed
   */
  async compactIfNeeded(): Promise<CompactResult> {
    if (!this.needsCompaction()) {
      return {
        compacted: false,
        messages: this.messages,
        summary: '',
        originalTokens: this.getTokenEstimate(),
        newTokens: this.getTokenEstimate(),
      };
    }

    // Perform compaction
    const result = await this.compactor.compact(this.messages);

    if (result.compacted) {
      // Update tracked messages with compacted version
      this.messages = result.messages;

      // Create a checkpoint handoff if not ephemeral
      if (!this.isEphemeral() && this.handoffManager) {
        const handoff: Omit<Handoff, 'id'> = {
          sessionId: this.sessionId,
          timestamp: new Date(),
          summary: result.summary,
          codeChanges: [],
          currentState: 'Context compacted due to token limit',
          blockers: [],
          nextSteps: [],
          patterns: [],
          metadata: {
            type: 'compaction_checkpoint',
            originalTokens: result.originalTokens,
            newTokens: result.newTokens,
          },
        };

        await this.handoffManager.create(handoff);
      }
    }

    return result;
  }

  // ===========================================================================
  // Context Methods
  // ===========================================================================

  /**
   * Build the system prompt with all context sources
   */
  buildSystemPrompt(): string {
    const sections: string[] = [];

    // Add project context from AGENTS.md
    if (this.loadedContext?.merged) {
      sections.push('# Project Context\n');
      sections.push(this.loadedContext.merged);
      sections.push('');
    }

    // Add ledger state
    if (this.loadedLedger && (this.loadedLedger.goal || this.loadedLedger.now)) {
      sections.push('# Session State\n');

      if (this.loadedLedger.goal) {
        sections.push(`**Goal**: ${this.loadedLedger.goal}`);
      }
      if (this.loadedLedger.now) {
        sections.push(`**Working on**: ${this.loadedLedger.now}`);
      }
      if (this.loadedLedger.next.length > 0) {
        sections.push(`**Next**: ${this.loadedLedger.next.slice(0, 3).join(', ')}`);
      }
      if (this.loadedLedger.constraints.length > 0) {
        sections.push(`**Constraints**: ${this.loadedLedger.constraints.join('; ')}`);
      }
      if (this.loadedLedger.workingFiles.length > 0) {
        sections.push(`**Files**: ${this.loadedLedger.workingFiles.join(', ')}`);
      }
      sections.push('');
    }

    // Add recent handoffs
    if (this.recentHandoffs.length > 0) {
      sections.push('# Previous Sessions\n');

      for (const handoff of this.recentHandoffs.slice(0, 3)) {
        sections.push(`## ${handoff.timestamp.toLocaleDateString()}`);
        sections.push(handoff.summary);

        if (handoff.nextSteps.length > 0) {
          sections.push(`**Pending**: ${handoff.nextSteps.slice(0, 3).join(', ')}`);
        }
        sections.push('');
      }
    }

    return sections.join('\n').trim();
  }

  // ===========================================================================
  // Ledger Methods
  // ===========================================================================

  /**
   * Get current ledger state
   */
  async getLedger(): Promise<Ledger> {
    this.ensureReady();
    return this.ledgerManager!.get();
  }

  /**
   * Update ledger with partial changes
   */
  async updateLedger(updates: Partial<Ledger>): Promise<Ledger> {
    this.ensureReady();

    // Skip persistence in ephemeral mode - just update in memory
    if (this.isEphemeral()) {
      this.loadedLedger = { ...(this.loadedLedger ?? this.getEmptyLedger()), ...updates };
      return this.loadedLedger;
    }

    this.loadedLedger = await this.ledgerManager!.update(updates);
    return this.loadedLedger;
  }

  /**
   * Add a working file to the ledger
   */
  async addWorkingFile(filePath: string): Promise<Ledger> {
    this.ensureReady();

    // Skip persistence in ephemeral mode
    if (this.isEphemeral()) {
      if (!this.loadedLedger) {
        this.loadedLedger = this.getEmptyLedger();
      }
      if (!this.loadedLedger.workingFiles.includes(filePath)) {
        this.loadedLedger.workingFiles.push(filePath);
      }
      return this.loadedLedger;
    }

    return this.ledgerManager!.addWorkingFile(filePath);
  }

  /**
   * Add a decision to the ledger
   */
  async addDecision(choice: string, reason: string): Promise<Ledger> {
    this.ensureReady();

    // Skip persistence in ephemeral mode
    if (this.isEphemeral()) {
      if (!this.loadedLedger) {
        this.loadedLedger = this.getEmptyLedger();
      }
      this.loadedLedger.decisions.push({ choice, reason, timestamp: new Date().toISOString() });
      return this.loadedLedger;
    }

    return this.ledgerManager!.addDecision(choice, reason);
  }

  private getEmptyLedger(): Ledger {
    return {
      goal: '',
      now: '',
      next: [],
      done: [],
      constraints: [],
      workingFiles: [],
      decisions: [],
    };
  }

  // ===========================================================================
  // Handoff Methods
  // ===========================================================================

  /**
   * Search handoffs by content
   */
  async searchHandoffs(query: string, limit = 5): Promise<HandoffSearchResult[]> {
    this.ensureReady();
    return this.handoffManager!.search(query, limit);
  }

  /**
   * Get handoff by ID
   */
  async getHandoff(handoffId: string): Promise<Handoff | null> {
    this.ensureReady();
    return this.handoffManager!.get(handoffId);
  }

  // ===========================================================================
  // State Methods
  // ===========================================================================

  /**
   * Get current session state
   */
  getState(): TuiSessionState {
    return this.state;
  }

  /**
   * Get session ID
   */
  getSessionId(): string {
    return this.sessionId;
  }

  /**
   * Get total token usage
   */
  getTokenUsage(): TokenUsage {
    return { ...this.totalTokenUsage };
  }

  // ===========================================================================
  // Context Audit Methods
  // ===========================================================================

  /**
   * Get the context audit data for this session
   */
  getContextAudit(): ContextAuditData | null {
    return this.contextAudit?.getData() ?? null;
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

  /**
   * Record a tool registration in the audit
   */
  recordTool(tool: { name: string; description: string; parameters: Record<string, unknown> }): void {
    this.contextAudit?.addTool(tool);
  }

  /**
   * Record a hook modification in the audit
   */
  recordHookModification(mod: {
    hookId: string;
    event: string;
    modification: string;
    charDelta: number;
  }): void {
    this.contextAudit?.addHookModification(mod);
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
      path.join(this.config.tronDir, 'sessions'),
      path.join(this.config.tronDir, 'memory'),
    ];

    for (const dir of dirs) {
      try {
        await fs.mkdir(dir, { recursive: true });
      } catch (error) {
        // Only throw if it's not an EEXIST error (directory already exists)
        const err = error as NodeJS.ErrnoException;
        if (err.code !== 'EEXIST') {
          throw error;
        }
      }
    }
  }

  private async initializeManagers(): Promise<void> {
    // Session Manager
    this.sessionManager = new SessionManager({
      sessionsDir: path.join(this.config.tronDir, 'sessions'),
      defaultModel: this.config.model,
      defaultProvider: this.config.provider,
    });

    // Handoff Manager
    this.handoffManager = new HandoffManager({
      dbPath: path.join(this.config.tronDir, 'memory-handoffs.db'),
    });
    await this.handoffManager.initialize();

    // Ledger Manager
    this.ledgerManager = new LedgerManager({
      ledgerDir: path.join(this.config.tronDir, 'memory'),
    });
    await this.ledgerManager.initialize();

    // Context Loader
    this.contextLoader = new ContextLoader({
      userHome: process.env.HOME ?? '',
      projectRoot: this.config.workingDirectory,
      contextFileNames: ['AGENTS.md', 'CLAUDE.md'],
      agentDir: '.tron',
    });
  }

  private async loadContext(): Promise<LoadedContext | null> {
    try {
      return await this.contextLoader!.load(this.config.workingDirectory);
    } catch (error) {
      console.warn('Failed to load context:', error);
      return null;
    }
  }

  private async loadLedger(): Promise<Ledger | null> {
    try {
      return await this.ledgerManager!.load();
    } catch (error) {
      console.warn('Failed to load ledger:', error);
      return null;
    }
  }

  private async loadRecentHandoffs(): Promise<Handoff[]> {
    try {
      return await this.handoffManager!.getRecent(3);
    } catch (error) {
      console.warn('Failed to load handoffs:', error);
      return [];
    }
  }

  private async createHandoff(): Promise<string> {
    const ledger = await this.ledgerManager!.get();

    const handoff: Omit<Handoff, 'id'> = {
      sessionId: this.sessionId,
      timestamp: new Date(),
      summary: this.generateSummary(ledger),
      codeChanges: [],
      currentState: ledger.now || 'Session completed',
      blockers: [],
      nextSteps: ledger.next.slice(0, 5),
      patterns: ledger.decisions.map(d => `${d.choice}: ${d.reason}`).slice(0, 3),
      metadata: {
        messageCount: this.messageCount,
        tokenUsage: this.totalTokenUsage,
        workingDirectory: this.config.workingDirectory,
      },
    };

    return this.handoffManager!.create(handoff);
  }

  private generateSummary(ledger: Ledger): string {
    const parts: string[] = [];

    if (ledger.now) {
      parts.push(`Worked on: ${ledger.now}`);
    }

    if (ledger.done.length > 0) {
      parts.push(`Completed: ${ledger.done.slice(-3).join(', ')}`);
    }

    parts.push(`${this.messageCount} messages exchanged`);

    return parts.join('. ') || 'Session completed';
  }

  private recordSystemPromptInAudit(systemPrompt: string): void {
    if (!this.contextAudit) return;

    // Build sections list for audit
    const sections: Array<{ name: string; content: string; source: string }> = [];

    // Project context section
    if (this.loadedContext?.merged) {
      sections.push({
        name: 'Project Context',
        content: this.loadedContext.merged,
        source: 'AGENTS.md hierarchy',
      });
    }

    // Ledger state section
    if (this.loadedLedger && (this.loadedLedger.goal || this.loadedLedger.now)) {
      const ledgerContent = this.buildLedgerContent();
      sections.push({
        name: 'Session State',
        content: ledgerContent,
        source: 'ledger.json',
      });
    }

    // Handoffs section
    if (this.recentHandoffs.length > 0) {
      const handoffsContent = this.buildHandoffsContent();
      sections.push({
        name: 'Previous Sessions',
        content: handoffsContent,
        source: 'memory-handoffs.db',
      });
    }

    this.contextAudit.setSystemPrompt({
      content: systemPrompt,
      sections,
    });
  }

  private buildLedgerContent(): string {
    const parts: string[] = [];
    if (this.loadedLedger?.now) parts.push(`Now: ${this.loadedLedger.now}`);
    if (this.loadedLedger?.next.length) parts.push(`Next: ${this.loadedLedger.next.join(', ')}`);
    return parts.join('\n');
  }

  private buildHandoffsContent(): string {
    return this.recentHandoffs.map(h => h.summary).join('\n\n');
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createTuiSession(config: TuiSessionConfig): TuiSession {
  return new TuiSession(config);
}
