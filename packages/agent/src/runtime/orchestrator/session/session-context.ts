/**
 * @fileoverview SessionContext - Per-Session State Management
 *
 * Encapsulates all per-session state using the extracted modules:
 * - EventPersister for linearized event persistence
 * - TurnManager for turn lifecycle and content tracking
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
 * const result = context.endTurn();
 * ```
 */
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '@infrastructure/logging/index.js';
import type { EventStore } from '@infrastructure/events/event-store.js';
import type {
  EventType,
  EventId,
  SessionId,
  SessionEvent as TronSessionEvent,
} from '@infrastructure/events/types.js';
import type { WorkingDirectory } from '@platform/session/working-directory.js';
import type { ProviderType } from '@core/types/messages.js';
import { detectProviderType } from '@llm/providers/token-normalizer.js';
import {
  EventPersister,
  createEventPersister,
} from '../persistence/event-persister.js';
import {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type EndTurnResult,
  type AssistantContentBlock,
} from '../turn/turn-manager.js';
import {
  SessionReconstructor,
  createSessionReconstructor,
} from './session-reconstructor.js';
import type { AccumulatedContent, InterruptedContent } from '../turn/turn-content-tracker.js';
import type { MessageWithEventId } from '@infrastructure/events/types.js';

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
    this.reconstructor = createSessionReconstructor();

    // Set provider type based on model for token normalization
    const providerType = detectProviderType(config.model);
    this.turnManager.setProviderType(providerType);

    logger.debug('Session context created', {
      sessionId: this.sessionId,
      model: this.model,
      providerType,
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

  /**
   * Update the provider type for token normalization.
   * Called when the model changes mid-session.
   */
  setProviderType(type: ProviderType): void {
    this.turnManager.setProviderType(type);
  }

  /**
   * Get the current provider type.
   */
  getProviderType(): ProviderType {
    return this.turnManager.getProviderType();
  }

  /**
   * Update provider type based on model ID.
   * Convenience method for when the model changes mid-session.
   */
  updateProviderTypeForModel(modelId: string): void {
    const type = detectProviderType(modelId);
    this.turnManager.setProviderType(type);
    logger.debug('Provider type updated for model', { modelId, providerType: type });
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
   * REQUIRES: setResponseTokenUsage() must be called before this method.
   */
  endTurn(): EndTurnResult {
    return this.turnManager.endTurn();
  }

  /**
   * Set token usage from API response EARLY (before tool execution).
   * This should be called when response_complete fires, enabling message.assistant
   * to include token data even for tool-using turns.
   */
  setResponseTokenUsage(tokenUsage: TokenUsage): void {
    this.turnManager.setResponseTokenUsage(tokenUsage);
  }

  /**
   * Get the last turn's raw token usage.
   * Available after setResponseTokenUsage() is called.
   */
  getLastTurnTokenUsage(): TokenUsage | undefined {
    return this.turnManager.getLastTurnTokenUsage();
  }

  /**
   * Get the last turn's normalized token usage.
   * Provides semantic clarity for UI display.
   */
  getLastNormalizedUsage() {
    return this.turnManager.getLastNormalizedUsage();
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
   * Set message event IDs from unified messagesWithEventIds array.
   * Extracts and flattens all eventIds for tracking (handles merged messages with multiple IDs).
   */
  setMessagesWithEventIds(messagesWithEventIds: MessageWithEventId[]): void {
    this.messageEventIds = [];
    for (const entry of messagesWithEventIds) {
      // Flatten all eventIds from this entry (supports merged messages)
      this.messageEventIds.push(...entry.eventIds);
    }
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

    // Restore reasoning level
    if (state.reasoningLevel) {
      this.reasoningLevel = state.reasoningLevel;
    }

    logger.debug('Session state restored from events', {
      sessionId: this.sessionId,
      currentTurn: state.currentTurn,
      wasInterrupted: state.wasInterrupted,
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
