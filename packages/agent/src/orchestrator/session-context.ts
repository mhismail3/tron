/**
 * @fileoverview SessionContext - Per-Session State Management
 *
 * Encapsulates all per-session state using the extracted modules:
 * - EventPersister for linearized event persistence
 * - TurnManager for turn lifecycle and content tracking
 * - PlanModeHandler for plan mode state
 * - SessionReconstructor for state restoration
 *
 * Each active session has its own SessionContext instance.
 *
 * ## Design Principles
 *
 * 1. **Encapsulation**: All session state in one place
 * 2. **Module Delegation**: Use extracted modules, don't duplicate logic
 * 3. **Clean Interface**: Simple methods for orchestrator to call
 * 4. **Testability**: Can be tested in isolation
 *
 * ## Usage
 *
 * ```typescript
 * const context = createSessionContext({
 *   sessionId,
 *   eventStore,
 *   initialHeadEventId,
 *   model: 'claude-sonnet-4-20250514',
 *   workingDirectory: '/path/to/project',
 * });
 *
 * // Event persistence
 * await context.appendEvent('message.user', { content: 'Hello' });
 *
 * // Turn management
 * context.startTurn(1);
 * context.addTextDelta('Response text');
 * const result = context.endTurn({ inputTokens: 100, outputTokens: 50 });
 *
 * // Plan mode
 * context.enterPlanMode('skill', ['Edit', 'Write']);
 * if (context.isToolBlocked('Edit')) { ... }
 * ```
 */
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '../logging/logger.js';
import type { EventStore } from '../events/event-store.js';
import type {
  EventType,
  EventId,
  SessionId,
  SessionEvent as TronSessionEvent,
} from '../events/types.js';
import type { WorkingDirectory } from '../session/working-directory.js';
import {
  EventPersister,
  createEventPersister,
} from './event-persister.js';
import {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type EndTurnResult,
  type AssistantContentBlock,
} from './turn-manager.js';
import {
  PlanModeHandler,
  createPlanModeHandler,
  type PlanModeState,
} from './handlers/plan-mode.js';
import {
  SessionReconstructor,
  createSessionReconstructor,
} from './session-reconstructor.js';
import type { AccumulatedContent, InterruptedContent } from './turn-content-tracker.js';

const logger = createLogger('session-context');

// =============================================================================
// Types
// =============================================================================

export interface SessionContextConfig {
  /** Session ID */
  sessionId: SessionId;
  /** EventStore instance */
  eventStore: EventStore;
  /** Initial head event ID (from session creation or resume) */
  initialHeadEventId: EventId;
  /** Model being used */
  model: string;
  /** Working directory path */
  workingDirectory: string;
  /** WorkingDirectory abstraction (optional) */
  workingDir?: WorkingDirectory;
  /** Initial reasoning level (optional) */
  reasoningLevel?: string;
}

// =============================================================================
// SessionContext Class
// =============================================================================

/**
 * Encapsulates per-session state and operations.
 *
 * Uses extracted modules for specific responsibilities:
 * - EventPersister: Event linearization and persistence
 * - TurnManager: Turn lifecycle and content tracking
 * - PlanModeHandler: Plan mode state
 */
export class SessionContext {
  // Core identity
  private readonly sessionId: SessionId;
  private readonly model: string;
  private readonly workingDirectory: string;
  private workingDir?: WorkingDirectory;

  // Extracted modules
  private readonly persister: EventPersister;
  private readonly turnManager: TurnManager;
  private readonly planModeHandler: PlanModeHandler;
  private readonly reconstructor: SessionReconstructor;

  // Processing state
  private processing: boolean = false;
  private lastActivity: Date = new Date();

  // Configuration
  private reasoningLevel?: string;

  // Message tracking (for context audit)
  private messageEventIds: (string | undefined)[] = [];

  constructor(config: SessionContextConfig) {
    this.sessionId = config.sessionId;
    this.model = config.model;
    this.workingDirectory = config.workingDirectory;
    this.workingDir = config.workingDir;
    this.reasoningLevel = config.reasoningLevel;

    // Initialize modules
    this.persister = createEventPersister({
      eventStore: config.eventStore,
      sessionId: config.sessionId,
      initialHeadEventId: config.initialHeadEventId,
    });

    this.turnManager = createTurnManager();
    this.planModeHandler = createPlanModeHandler();
    this.reconstructor = createSessionReconstructor();

    logger.debug('Session context created', {
      sessionId: this.sessionId,
      model: this.model,
    });
  }

  // ===========================================================================
  // Identity & Configuration
  // ===========================================================================

  getSessionId(): SessionId {
    return this.sessionId;
  }

  getModel(): string {
    return this.model;
  }

  getWorkingDirectory(): string {
    return this.workingDirectory;
  }

  getWorkingDir(): WorkingDirectory | undefined {
    return this.workingDir;
  }

  setWorkingDir(workingDir: WorkingDirectory): void {
    this.workingDir = workingDir;
  }

  getReasoningLevel(): string | undefined {
    return this.reasoningLevel;
  }

  setReasoningLevel(level: string | undefined): void {
    this.reasoningLevel = level;
  }

  // ===========================================================================
  // Event Persistence (delegated to EventPersister)
  // ===========================================================================

  /**
   * Append an event and wait for the result.
   */
  async appendEvent(
    type: EventType,
    payload: Record<string, unknown>
  ): Promise<TronSessionEvent | null> {
    return this.persister.appendAsync(type, payload);
  }

  /**
   * Append an event without waiting (fire-and-forget).
   */
  appendEventFireAndForget(
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ): void {
    this.persister.append(type, payload, onCreated);
  }

  /**
   * Append multiple events atomically.
   */
  async appendMultipleEvents(
    requests: Array<{ type: EventType; payload: Record<string, unknown> }>
  ): Promise<Array<TronSessionEvent | null>> {
    return this.persister.appendMultiple(requests);
  }

  /**
   * Wait for all pending event appends to complete.
   */
  async flushEvents(): Promise<void> {
    return this.persister.flush();
  }

  /**
   * Get the current pending head event ID.
   */
  getPendingHeadEventId(): EventId {
    return this.persister.getPendingHeadEventId();
  }

  /**
   * Check if there was a persistence error.
   */
  hasPersistenceError(): boolean {
    return this.persister.hasError();
  }

  /**
   * Get the persistence error if any.
   */
  getPersistenceError(): Error | undefined {
    return this.persister.getError();
  }

  /**
   * Run an operation within the linearization chain.
   *
   * Use for operations that need to use EventStore methods directly
   * (like deleteMessage) but still need proper linearization.
   *
   * @param operation - Async function that receives parentId and returns new event
   * @returns The event returned by the operation
   */
  async runInChain<T extends TronSessionEvent>(
    operation: (parentId: EventId) => Promise<T>
  ): Promise<T> {
    return this.persister.runInChain(operation);
  }

  // ===========================================================================
  // Turn Management (delegated to TurnManager)
  // ===========================================================================

  /**
   * Start a new turn.
   */
  startTurn(turn: number): void {
    this.turnManager.startTurn(turn);
  }

  /**
   * End the current turn and get content.
   */
  endTurn(tokenUsage?: TokenUsage): EndTurnResult {
    return this.turnManager.endTurn(tokenUsage);
  }

  /**
   * Get current turn number.
   */
  getCurrentTurn(): number {
    return this.turnManager.getCurrentTurn();
  }

  /**
   * Get turn start time.
   */
  getTurnStartTime(): number | undefined {
    return this.turnManager.getTurnStartTime();
  }

  /**
   * Add a text delta.
   */
  addTextDelta(text: string): void {
    this.turnManager.addTextDelta(text);
  }

  /**
   * Add a thinking delta.
   * Thinking content is accumulated separately and prepended to the message.
   */
  addThinkingDelta(thinking: string): void {
    this.turnManager.addThinkingDelta(thinking);
  }

  /**
   * Set the signature for the current thinking block.
   * Called when thinking_end event is received with the complete signature.
   * IMPORTANT: API requires signature when sending thinking blocks back.
   */
  setThinkingSignature(signature: string): void {
    this.turnManager.setThinkingSignature(signature);
  }

  /**
   * Register ALL tool intents from tool_use_batch event.
   * Called BEFORE any tool execution starts to enable linear event ordering.
   */
  registerToolIntents(
    toolCalls: Array<{ id: string; name: string; arguments: Record<string, unknown> }>
  ): void {
    this.turnManager.registerToolIntents(toolCalls);
  }

  /**
   * Start tracking a tool call.
   */
  startToolCall(
    toolCallId: string,
    toolName: string,
    args: Record<string, unknown>
  ): void {
    this.turnManager.startToolCall(toolCallId, toolName, args);
  }

  /**
   * End tracking a tool call.
   */
  endToolCall(toolCallId: string, result: string, isError: boolean): void {
    this.turnManager.endToolCall(toolCallId, result, isError);
  }

  /**
   * Get accumulated content for client catch-up.
   */
  getAccumulatedContent(): AccumulatedContent {
    return this.turnManager.getAccumulatedContent();
  }

  /**
   * Check if there's accumulated content.
   */
  hasAccumulatedContent(): boolean {
    return this.turnManager.hasAccumulatedContent();
  }

  /**
   * Build interrupted content for persistence.
   */
  buildInterruptedContent(): InterruptedContent {
    return this.turnManager.buildInterruptedContent();
  }

  // ===========================================================================
  // Pre-Tool Content Flush (for Linear Event Ordering)
  // ===========================================================================

  /**
   * Check if pre-tool content has been flushed this turn.
   */
  hasPreToolContentFlushed(): boolean {
    return this.turnManager.hasPreToolContentFlushed();
  }

  /**
   * Flush accumulated content BEFORE first tool execution.
   * Returns content blocks or null if nothing to flush.
   */
  flushPreToolContent(): AssistantContentBlock[] | null {
    return this.turnManager.flushPreToolContent();
  }

  // ===========================================================================
  // Agent Lifecycle
  // ===========================================================================

  /**
   * Called when agent run starts.
   */
  onAgentStart(): void {
    this.turnManager.onAgentStart();
  }

  /**
   * Called when agent run ends.
   */
  onAgentEnd(): void {
    this.turnManager.onAgentEnd();
  }

  // ===========================================================================
  // Plan Mode (delegated to PlanModeHandler)
  // ===========================================================================

  /**
   * Check if plan mode is active.
   */
  isInPlanMode(): boolean {
    return this.planModeHandler.isActive();
  }

  /**
   * Get blocked tools list.
   */
  getBlockedTools(): string[] {
    return this.planModeHandler.getBlockedTools();
  }

  /**
   * Check if a specific tool is blocked.
   */
  isToolBlocked(toolName: string): boolean {
    return this.planModeHandler.isToolBlocked(toolName);
  }

  /**
   * Get full plan mode state.
   */
  getPlanModeState(): PlanModeState {
    return this.planModeHandler.getState();
  }

  /**
   * Enter plan mode.
   */
  enterPlanMode(skillName: string, blockedTools: string[]): void {
    this.planModeHandler.enter(skillName, blockedTools);
  }

  /**
   * Exit plan mode.
   */
  exitPlanMode(): void {
    this.planModeHandler.exit();
  }

  // ===========================================================================
  // Processing State
  // ===========================================================================

  /**
   * Check if session is currently processing.
   */
  isProcessing(): boolean {
    return this.processing;
  }

  /**
   * Set processing state.
   */
  setProcessing(processing: boolean): void {
    this.processing = processing;
    if (processing) {
      this.lastActivity = new Date();
    }
  }

  /**
   * Get last activity time.
   */
  getLastActivity(): Date {
    return this.lastActivity;
  }

  /**
   * Update last activity time.
   */
  touch(): void {
    this.lastActivity = new Date();
  }

  // ===========================================================================
  // Message Event ID Tracking
  // ===========================================================================

  /**
   * Get message event IDs for context audit.
   */
  getMessageEventIds(): (string | undefined)[] {
    return this.messageEventIds;
  }

  /**
   * Set message event IDs (from state restoration).
   */
  setMessageEventIds(ids: (string | undefined)[]): void {
    this.messageEventIds = ids;
  }

  /**
   * Add a message event ID.
   */
  addMessageEventId(id: string | undefined): void {
    this.messageEventIds.push(id);
  }

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  /**
   * Restore state from events (used when resuming session).
   */
  restoreFromEvents(events: TronSessionEvent[]): void {
    const state = this.reconstructor.reconstruct(events);

    // Restore plan mode
    this.planModeHandler.setState(state.planMode);

    // Restore reasoning level
    if (state.reasoningLevel) {
      this.reasoningLevel = state.reasoningLevel;
    }

    logger.debug('Session state restored from events', {
      sessionId: this.sessionId,
      currentTurn: state.currentTurn,
      wasInterrupted: state.wasInterrupted,
      planModeActive: state.planMode.isActive,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a SessionContext instance.
 */
export function createSessionContext(config: SessionContextConfig): SessionContext {
  return new SessionContext(config);
}
