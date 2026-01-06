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
} from '@tron/core';

const logger = createLogger('event-store-orchestrator');

// =============================================================================
// Content Block Utilities
// =============================================================================

/**
 * Maximum size for tool result content before truncation (10KB)
 */
const MAX_TOOL_RESULT_SIZE = 10 * 1024;

/**
 * Maximum size for tool input arguments before truncation (5KB)
 */
const MAX_TOOL_INPUT_SIZE = 5 * 1024;

/**
 * Truncate a string to the specified max length, adding a truncation notice
 */
function truncateString(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  const truncated = str.slice(0, maxLength);
  const remaining = str.length - maxLength;
  return `${truncated}\n\n... [truncated ${remaining} characters]`;
}

/**
 * Normalize and sanitize a content block for storage.
 * Ensures all required fields are present and applies truncation for large content.
 */
function normalizeContentBlock(block: unknown): Record<string, unknown> | null {
  if (typeof block !== 'object' || block === null) return null;

  const b = block as Record<string, unknown>;
  const type = b.type;

  if (typeof type !== 'string') return null;

  switch (type) {
    case 'text':
      return {
        type: 'text',
        text: typeof b.text === 'string' ? b.text : String(b.text ?? ''),
      };

    case 'tool_use': {
      const toolName = typeof b.name === 'string' ? b.name : String(b.name ?? 'unknown');

      // IMPORTANT: The Anthropic API uses 'input', but our internal ToolCall type uses 'arguments'
      // We need to check for BOTH to handle both sources correctly
      const rawInput = b.input ?? b.arguments;
      const hasInputKey = 'input' in b;
      const hasArgumentsKey = 'arguments' in b;

      logger.debug('Normalizing tool_use block', {
        toolName,
        blockKeys: Object.keys(b),
        hasInputKey,
        hasArgumentsKey,
        inputType: typeof rawInput,
        inputIsObject: rawInput !== null && typeof rawInput === 'object',
        inputKeys: rawInput && typeof rawInput === 'object' ? Object.keys(rawInput as object) : [],
        inputPreview: rawInput ? JSON.stringify(rawInput).slice(0, 200) : 'undefined/null',
      });

      // Preserve the full input object with potential truncation for very large inputs
      let input = rawInput;
      if (input && typeof input === 'object') {
        // Deep clone to avoid mutating original and ensure it serializes correctly
        try {
          const inputStr = JSON.stringify(input);
          // Parse it back to ensure clean serialization (removes any class instances/prototypes)
          input = JSON.parse(inputStr);
          if (inputStr.length > MAX_TOOL_INPUT_SIZE) {
            // For very large inputs, store a truncated version
            input = {
              _truncated: true,
              _originalSize: inputStr.length,
              _preview: inputStr.slice(0, MAX_TOOL_INPUT_SIZE),
            };
          }
        } catch (e) {
          // If JSON.stringify fails, try to extract what we can
          logger.warn('Failed to serialize tool input', { toolName, error: String(e) });
          input = { _serializationError: true };
        }
      } else if (input === undefined || input === null) {
        // Explicitly log when input is missing
        logger.warn('Tool use block has no input', { toolName, hasInputKey, hasArgumentsKey });
        input = {};
      }

      const result = {
        type: 'tool_use' as const,
        id: typeof b.id === 'string' ? b.id : String(b.id ?? ''),
        name: toolName,
        input: input,
      };

      logger.debug('Normalized tool_use result', {
        toolName,
        inputKeys: Object.keys(result.input as object),
        hasContent: Object.keys(result.input as object).length > 0,
      });

      return result;
    }

    case 'tool_result': {
      // IMPORTANT: Anthropic API uses 'tool_use_id', but our internal ToolResultMessage uses 'toolCallId'
      // We need to check for BOTH to handle both sources correctly
      const toolUseId = typeof b.tool_use_id === 'string' ? b.tool_use_id :
                        typeof b.toolCallId === 'string' ? b.toolCallId :
                        String(b.tool_use_id ?? b.toolCallId ?? '');
      const blockKeys = Object.keys(b);
      const rawContent = b.content;
      const isError = b.is_error === true || b.isError === true;

      logger.debug('Normalizing tool_result block', {
        toolUseId: toolUseId.slice(0, 20) + '...',
        blockKeys,
        contentType: typeof rawContent,
        contentIsArray: Array.isArray(rawContent),
        contentLength: typeof rawContent === 'string' ? rawContent.length :
                       Array.isArray(rawContent) ? rawContent.length : 0,
        contentPreview: typeof rawContent === 'string' ? rawContent.slice(0, 100) :
                       Array.isArray(rawContent) ? JSON.stringify(rawContent).slice(0, 100) : 'N/A',
      });

      // Handle content which can be a string or array
      let content = rawContent;

      if (typeof content === 'string') {
        // Truncate very large string results
        if (content.length > MAX_TOOL_RESULT_SIZE) {
          content = truncateString(content, MAX_TOOL_RESULT_SIZE);
        }
      } else if (Array.isArray(content)) {
        // Content is an array of content parts (e.g., text + images)
        // Extract text and truncate if needed
        const textParts = content
          .filter((p): p is { type: string; text: string } =>
            typeof p === 'object' && p !== null && p.type === 'text' && typeof p.text === 'string'
          )
          .map(p => p.text)
          .join('\n');

        content = textParts.length > MAX_TOOL_RESULT_SIZE
          ? truncateString(textParts, MAX_TOOL_RESULT_SIZE)
          : textParts || JSON.stringify(rawContent);
      } else if (content !== undefined && content !== null) {
        content = String(content);
      } else {
        content = '';
      }

      const result = {
        type: 'tool_result' as const,
        tool_use_id: toolUseId,
        content,
        is_error: isError,
      };

      logger.debug('Normalized tool_result result', {
        toolUseId: toolUseId.slice(0, 20) + '...',
        contentLength: typeof result.content === 'string' ? result.content.length : 0,
        isError: result.is_error,
      });

      return result;
    }

    case 'thinking':
      return {
        type: 'thinking',
        thinking: typeof b.thinking === 'string' ? b.thinking : String(b.thinking ?? ''),
      };

    default:
      // Unknown type - preserve as-is
      return { ...b };
  }
}

/**
 * Normalize an array of content blocks for storage
 */
function normalizeContentBlocks(content: unknown): Record<string, unknown>[] {
  if (!Array.isArray(content)) {
    // Single string content
    if (typeof content === 'string') {
      return [{ type: 'text', text: content }];
    }
    return [];
  }

  return content
    .map(normalizeContentBlock)
    .filter((b): b is Record<string, unknown> => b !== null);
}

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

    // Default event store path
    const eventStoreDbPath = config.eventStoreDbPath ??
      path.join(os.homedir(), '.tron', 'events.db');

    // Initialize EventStore
    this.eventStore = new EventStore(eventStoreDbPath);

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

    // Append session end event
    await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'session.end',
      payload: {
        reason: 'completed',
        timestamp: new Date().toISOString(),
      },
    });

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

      const sessions: SessionInfo[] = [];
      for (const a of active) {
        const session = await this.eventStore.getSession(a.sessionId);
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

    const previousHeadEventId = session.headEventId!;

    await this.eventStore.rewind(sessionId as SessionId, toEventId as EventId);

    // If this is an active session, refresh the cached data
    // CRITICAL: Sync in-memory head after rewind to prevent race conditions
    // Without this, the next event would chain to the old head instead of rewind point
    const active = this.activeSessions.get(sessionId);
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
      // Record user message event
      await this.eventStore.append({
        sessionId: active.sessionId,
        type: 'message.user',
        payload: { content: options.prompt },
      });

      // Track timing for latency measurement (Phase 1)
      const runStartTime = Date.now();

      // Run agent
      const runResult = await active.agent.run(options.prompt);
      active.lastActivity = new Date();

      // Calculate latency (Phase 1)
      const runLatency = Date.now() - runStartTime;

      // Record assistant response event
      // Only store assistant content from the CURRENT turn (after the last user message)
      // This preserves tool_use blocks within a turn while avoiding cross-turn accumulation
      let lastUserIndex = -1;
      for (let i = runResult.messages.length - 1; i >= 0; i--) {
        const msg = runResult.messages[i];
        if (msg && msg.role === 'user') {
          lastUserIndex = i;
          break;
        }
      }

      // Get all assistant messages after the last user message (current turn only)
      const currentTurnAssistantMessages = runResult.messages
        .slice(lastUserIndex + 1)
        .filter((m: any) => m.role === 'assistant');

      // Combine all content blocks from current turn's assistant messages
      const currentTurnContent = currentTurnAssistantMessages.flatMap((m: any) =>
        Array.isArray(m.content) ? m.content : [{ type: 'text' as const, text: String(m.content) }]
      );

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

      // Phase 1: Store enriched assistant message with all metadata
      await this.eventStore.append({
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
      });

      // Also record tool_result blocks from tool result messages
      // TronAgent stores these as ToolResultMessage with role: 'toolResult'
      // Only get tool results from the CURRENT turn (after the last user message)
      // Note: toolResult messages come BETWEEN assistant messages, not after them
      const currentTurnToolResults = runResult.messages
        .slice(lastUserIndex + 1)
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

        await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'message.user',
          payload: { content: normalizedToolResults },
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

      // Phase 3: Store error.agent event for agent-level errors
      try {
        await this.eventStore.append({
          sessionId: active.sessionId,
          type: 'error.agent',
          payload: {
            error: error instanceof Error ? error.message : String(error),
            code: error instanceof Error ? error.name : undefined,
            recoverable: false,
          },
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

    active.isProcessing = false;
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

    // Record model switch event
    await this.eventStore.append({
      sessionId: sessionId as SessionId,
      type: 'config.model_switch',
      payload: {
        previousModel,
        newModel: model,
      },
    });

    // Update active session if exists
    const active = this.activeSessions.get(sessionId);
    if (active) {
      active.model = model;
      active.agent = await this.createAgentForSession(
        active.sessionId,
        active.workingDirectory,
        model
      );
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
   * Uses in-memory head tracking to prevent race conditions where
   * multiple events fire before DB updates complete.
   *
   * CRITICAL: This solves the spurious branching bug where events
   * A, B, C all read the same headEventId before any updates.
   *
   * The key insight: we update pendingHeadEventId SYNCHRONOUSLY before
   * any async DB operation, ensuring each subsequent event gets the
   * correct parentId even if the previous DB write hasn't finished.
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

    if (!active.pendingHeadEventId) {
      logger.error('Cannot append event: no pending head event ID', { sessionId, type });
      return;
    }

    // Capture the parent ID from our in-memory state (NOT from DB)
    const parentId = active.pendingHeadEventId;

    // Chain this append to the previous one, passing the actual event ID back
    active.appendPromiseChain = active.appendPromiseChain
      .then(async () => {
        try {
          const event = await this.eventStore.append({
            sessionId,
            type,
            payload,
            parentId, // Use our tracked parent, not DB head
          });
          // Update in-memory head with the ACTUAL event ID from DB
          active.pendingHeadEventId = event.id;
        } catch (err) {
          logger.error(`Failed to store ${type} event`, { err, sessionId });
          // Don't rethrow - allow subsequent events to proceed
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
        this.emit('agent_event', {
          type: 'agent.text_delta',
          sessionId,
          timestamp,
          data: { delta: event.content },
        });
        break;

      case 'tool_execution_start':
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
        this.emit('agent_event', {
          type: 'agent.turn_start',
          sessionId,
          timestamp,
          data: {},
        });
        break;

      case 'agent_end':
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

  private cleanupInactiveSessions(): void {
    const inactiveThreshold = 30 * 60 * 1000; // 30 minutes
    const now = Date.now();

    for (const [sessionId, active] of this.activeSessions.entries()) {
      if (active.isProcessing) continue;

      const inactiveTime = now - active.lastActivity.getTime();
      if (inactiveTime > inactiveThreshold) {
        logger.info('Cleaning up inactive session', {
          sessionId,
          inactiveMinutes: Math.floor(inactiveTime / 60000),
        });
        this.activeSessions.delete(sessionId);
      }
    }
  }
}
