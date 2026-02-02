/**
 * @fileoverview Agent Runner
 *
 * Extracted from EventStoreOrchestrator as part of modular refactoring.
 * Handles the complete agent execution flow including:
 * - Context injection (skills, subagents, todos)
 * - User content building (text, images, documents)
 * - Agent execution coordination
 * - Interrupt handling and partial content persistence
 * - Error handling and event emission
 *
 * ## Design
 *
 * AgentRunner is a stateless coordinator that operates on provided dependencies.
 * All state lives in ActiveSession and SessionContext. This design:
 * - Improves testability (easy to mock dependencies)
 * - Reduces coupling to orchestrator
 * - Makes the execution flow explicit and traceable
 *
 * ## Event Flow
 *
 * 1. Pre-execution: Flush pending events, inject contexts
 * 2. Execution: Record user message, run agent
 * 3. Post-execution: Handle completion/interrupt/error, emit events
 *
 * All event persistence goes through SessionContext.appendEvent() which
 * handles linearization automatically.
 */
// Direct imports to avoid circular dependencies through index.js
import { randomUUID } from 'crypto';
import { createLogger } from '../logging/index.js';
import { withLoggingContext, getLoggingContext } from '../logging/log-context.js';
import { normalizeContentBlocks } from '../utils/content-normalizer.js';
import { PersistenceError } from '../utils/errors.js';
import type { RunResult } from '../agent/types.js';
import type { UserContent } from '../types/messages.js';
import type { SkillLoader, PlanModeCallback } from './operations/skill-loader.js';
import type {
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
} from './types.js';

const logger = createLogger('agent-runner');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for AgentRunner.
 * All dependencies are injected to avoid circular imports and improve testability.
 */
export interface AgentRunnerConfig {
  /** SkillLoader instance for loading skill context */
  skillLoader: SkillLoader;

  /** Emit events to orchestrator (agent_turn, agent_event) */
  emit: (event: string, data: unknown) => void;

  /** Enter plan mode for a session */
  enterPlanMode: (
    sessionId: string,
    opts: { skillName: string; blockedTools: string[] }
  ) => Promise<void>;

  /** Check if session is in plan mode */
  isInPlanMode: (sessionId: string) => boolean;

  /** Build context string from pending subagent results */
  buildSubagentResultsContext: (active: ActiveSession) => string | undefined;
}

/**
 * Result of building user message content.
 * Separates the content array from the payload for flexibility.
 */
interface UserContentResult {
  /** Content array for the agent (may include images, documents) */
  content: UserContent[];
  /** Simplified content for event payload (string if text-only) */
  messageContent: string | UserContent[];
  /** Whether content is simple text-only */
  isSimpleTextOnly: boolean;
}

/**
 * Payload for user message event.
 * Uses index signature to be compatible with SessionContext.appendEvent.
 */
interface UserMessagePayload {
  content: unknown;
  skills?: { name: string; source: string }[];
  spells?: { name: string; source: string }[];
  [key: string]: unknown; // Allow additional properties for Record<string, unknown> compatibility
}

// =============================================================================
// AgentRunner Class
// =============================================================================

/**
 * Coordinates agent execution for a session.
 *
 * Extracted from EventStoreOrchestrator to reduce complexity and improve
 * maintainability. Handles the complete run flow from context injection
 * through completion/error handling.
 */
export class AgentRunner {
  private config: AgentRunnerConfig;

  constructor(config: AgentRunnerConfig) {
    this.config = config;
  }

  // ===========================================================================
  // Main Entry Point
  // ===========================================================================

  /**
   * Execute an agent run for the given session.
   *
   * This is the main entry point, called by EventStoreOrchestrator.runAgent().
   * The orchestrator handles session lookup, auto-resume, and processing state.
   * This method handles everything else.
   *
   * @param active - The active session to run
   * @param options - Run options including prompt, attachments, skills
   * @returns Array of run results
   * @throws On agent error (after persisting error event)
   */
  async run(active: ActiveSession, options: AgentRunOptions): Promise<RunResult[]> {
    // Get parent trace context (exists if this is a subagent run)
    const parentContext = getLoggingContext();
    const parentTraceId = parentContext.traceId ?? null;
    const depth = parentTraceId ? (parentContext.depth ?? 0) + 1 : 0;

    // Wrap entire agent run with logging context for session and trace correlation
    return withLoggingContext(
      {
        sessionId: options.sessionId,
        traceId: randomUUID(),
        parentTraceId,
        depth,
      },
      async () => this.executeRun(active, options)
    );
  }

  // ===========================================================================
  // Core Execution (Private)
  // ===========================================================================

  /**
   * Internal execution logic wrapped by logging context.
   */
  private async executeRun(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<RunResult[]> {
    try {
      // Phase 1: Pre-execution setup
      await this.preExecutionSetup(active, options);

      // Phase 2: Build and record user message
      const { messageContent } = await this.buildAndRecordUserMessage(active, options);

      // Phase 3: Handle reasoning level changes
      await this.handleReasoningLevel(active, options);

      // Phase 4: Transform content and execute agent
      const llmContent = this.config.skillLoader.transformContentForLLM(messageContent);
      const runResult = await active.agent.run(llmContent);

      // Update activity timestamp
      active.lastActivity = new Date();
      active.sessionContext.touch();

      // Phase 5: Handle result (interrupt, completion, or error in catch)
      if (runResult.interrupted) {
        return this.handleInterrupt(active, runResult, options);
      }

      return this.handleCompletion(active, runResult, options);
    } catch (error) {
      return this.handleError(active, error, options);
    }
  }

  // ===========================================================================
  // Phase 1: Pre-execution Setup
  // ===========================================================================

  /**
   * Prepare session for agent execution.
   * Flushes pending events and injects all contexts.
   */
  private async preExecutionSetup(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> {
    // CRITICAL: Wait for any pending stream events to complete before appending message events
    // This prevents race conditions where stream events (turn_start, etc.) capture wrong parentId
    await active.sessionContext.flushEvents();

    // Inject all contexts
    await this.injectSkillContext(active, options);
    this.injectSubagentContext(active);
    this.injectTodoContext(active);
  }

  // ===========================================================================
  // Context Injection
  // ===========================================================================

  /**
   * Load and inject skill context into the agent.
   */
  private async injectSkillContext(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> {
    // Build plan mode callback to enable skill-triggered plan mode
    const planModeCallback: PlanModeCallback = {
      enterPlanMode: async (skillName: string, blockedTools: string[]) => {
        await this.config.enterPlanMode(active.sessionId, { skillName, blockedTools });
      },
      isInPlanMode: () => this.config.isInPlanMode(active.sessionId),
    };

    const skillContext = await this.config.skillLoader.loadSkillContextForPrompt(
      {
        sessionId: active.sessionId,
        skillTracker: active.skillTracker,
        sessionContext: active.sessionContext,
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
  }

  /**
   * Inject pending subagent results context into the agent.
   */
  private injectSubagentContext(active: ActiveSession): void {
    const subagentResultsContext = this.config.buildSubagentResultsContext(active);
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
  }

  /**
   * Inject todo context into the agent.
   */
  private injectTodoContext(active: ActiveSession): void {
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
  }

  // ===========================================================================
  // Phase 2: User Message Building
  // ===========================================================================

  /**
   * Build user content and record the user message event.
   */
  private async buildAndRecordUserMessage(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<UserContentResult> {
    // Build user content from prompt and attachments
    const contentResult = this.buildUserContent(options);

    // Build and record user message event
    const payload = this.buildUserMessagePayload(options, contentResult.messageContent);
    const userMsgEvent = await active.sessionContext.appendEvent('message.user', payload);

    // Track eventId for context manager message
    if (userMsgEvent) {
      active.sessionContext.addMessageEventId(userMsgEvent.id);
      logger.debug('[LINEARIZE] message.user appended', {
        sessionId: active.sessionId,
        eventId: userMsgEvent.id,
      });
    }

    return contentResult;
  }

  /**
   * Build user content array from prompt and attachments.
   */
  private buildUserContent(options: AgentRunOptions): UserContentResult {
    const userContent: UserContent[] = [];

    // Add text prompt
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
      contentBlocks: userContent.length,
      hasImages: userContent.some(c => c.type === 'image'),
      hasDocuments: userContent.some(c => c.type === 'document'),
      hasTextFiles: userContent.filter(c => c.type === 'text').length > 1,
    });

    // Determine if we can use simple string format (backward compat) or need full content array
    const firstContent = userContent[0];
    const isSimpleTextOnly = userContent.length === 1 && firstContent?.type === 'text';
    const messageContent = isSimpleTextOnly ? options.prompt : userContent;

    return {
      content: userContent,
      messageContent: messageContent as string | UserContent[],
      isSimpleTextOnly,
    };
  }

  /**
   * Build user message payload with optional skills and spells.
   */
  private buildUserMessagePayload(
    options: AgentRunOptions,
    content: unknown
  ): UserMessagePayload {
    const payload: UserMessagePayload = { content };

    if (options.skills && options.skills.length > 0) {
      payload.skills = options.skills.map(s => ({ name: s.name, source: s.source }));
    }
    if (options.spells && options.spells.length > 0) {
      payload.spells = options.spells.map(s => ({ name: s.name, source: s.source }));
    }

    return payload;
  }

  // ===========================================================================
  // Phase 3: Reasoning Level
  // ===========================================================================

  /**
   * Handle reasoning level changes (for OpenAI Codex models).
   */
  private async handleReasoningLevel(
    active: ActiveSession,
    options: AgentRunOptions
  ): Promise<void> {
    if (!options.reasoningLevel) return;
    if (options.reasoningLevel === active.sessionContext.getReasoningLevel()) return;

    const previousLevel = active.sessionContext.getReasoningLevel();
    active.agent.setReasoningLevel(options.reasoningLevel);
    active.sessionContext.setReasoningLevel(options.reasoningLevel);

    // Persist reasoning level change as linearized event
    const reasoningEvent = await active.sessionContext.appendEvent('config.reasoning_level', {
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

  // ===========================================================================
  // Phase 5a: Interrupt Handling
  // ===========================================================================

  /**
   * Handle an interrupted agent run.
   * Persists partial content and emits interruption events.
   */
  private async handleInterrupt(
    active: ActiveSession,
    runResult: RunResult,
    options: AgentRunOptions
  ): Promise<RunResult[]> {
    const accumulated = active.sessionContext.getAccumulatedContent();
    logger.info('Agent run interrupted', {
      sessionId: options.sessionId,
      turn: runResult.turns,
      hasPartialContent: !!runResult.partialContent,
      accumulatedTextLength: accumulated.text?.length ?? 0,
      toolCallsCount: accumulated.toolCalls?.length ?? 0,
    });

    // Notify the RPC caller about the interruption
    if (options.onEvent) {
      options.onEvent({
        type: 'turn_interrupted',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        runId: options.runId,
        data: {
          interrupted: true,
          partialContent: runResult.partialContent,
        },
      });
    }

    // Persist partial content
    await this.persistInterruptedContent(active, runResult);

    // Persist notification.interrupted event as first-class ledger entry
    const interruptNotificationEvent = await active.sessionContext.appendEvent(
      'notification.interrupted',
      {
        timestamp: new Date().toISOString(),
        turn: runResult.turns || 1,
      }
    );

    if (interruptNotificationEvent) {
      logger.info('Persisted notification.interrupted event', {
        sessionId: active.sessionId,
        eventId: interruptNotificationEvent.id,
      });
    }

    // Mark session as interrupted in metadata
    active.wasInterrupted = true;

    // Clear turn tracking state via SessionContext
    active.sessionContext.onAgentEnd();

    return [runResult];
  }

  /**
   * Persist partial content from an interrupted run.
   * CRITICAL: This ensures partial work survives session resume.
   */
  private async persistInterruptedContent(
    active: ActiveSession,
    runResult: RunResult
  ): Promise<void> {
    // Build content blocks from accumulated state (preserves exact interleaving order)
    const { assistantContent, toolResultContent } = active.sessionContext.buildInterruptedContent();

    // Only persist if there's actual content
    if (assistantContent.length === 0 && toolResultContent.length === 0) {
      return;
    }

    // Wait for any pending stream events
    await active.sessionContext.flushEvents();

    // 1. Persist assistant message with tool_use blocks
    if (assistantContent.length > 0) {
      const normalizedAssistantContent = normalizeContentBlocks(assistantContent);

      const assistantMsgEvent = await active.sessionContext.appendEvent('message.assistant', {
        content: normalizedAssistantContent,
        tokenUsage: runResult.totalTokenUsage,
        turn: runResult.turns || 1,
        model: active.sessionContext.getModel(),
        stopReason: 'interrupted',
        interrupted: true,
      });

      if (assistantMsgEvent) {
        logger.info('Persisted interrupted assistant message', {
          sessionId: active.sessionId,
          eventId: assistantMsgEvent.id,
          contentBlocks: normalizedAssistantContent.length,
          hasAccumulatedContent: active.sessionContext.hasAccumulatedContent(),
        });
      }
    }

    // 2. Persist tool results as user message (like normal flow)
    if (toolResultContent.length > 0) {
      const normalizedToolResults = normalizeContentBlocks(toolResultContent);

      const toolResultEvent = await active.sessionContext.appendEvent('message.user', {
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

  // ===========================================================================
  // Phase 5b: Completion Handling
  // ===========================================================================

  /**
   * Handle successful agent completion.
   */
  private async handleCompletion(
    active: ActiveSession,
    runResult: RunResult,
    options: AgentRunOptions
  ): Promise<RunResult[]> {
    // Wait for all linearized events to complete before returning
    await active.sessionContext.flushEvents();

    logger.debug('Agent run completed', {
      sessionId: active.sessionId,
      turns: runResult.turns,
      stoppedReason: runResult.stoppedReason,
    });

    // Emit turn completion event
    this.emitTurnComplete(active.sessionId, runResult, options.onEvent, options.runId);

    // Emit agent.complete AFTER all linearized events are persisted
    this.emitAgentComplete(options.sessionId, !runResult.error, runResult.error, options.runId);

    return [runResult];
  }

  // ===========================================================================
  // Phase 5c: Error Handling
  // ===========================================================================

  /**
   * Handle agent execution error.
   * Persists error event and re-throws.
   */
  private async handleError(
    active: ActiveSession,
    error: unknown,
    options: AgentRunOptions
  ): Promise<never> {
    logger.error('Agent run error', { sessionId: options.sessionId, error });

    // Store error.agent event for agent-level errors (linearized)
    try {
      // CRITICAL: Wait for any pending events before appending
      await active.sessionContext.flushEvents();
      const errorEvent = await active.sessionContext.appendEvent('error.agent', {
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
      // Wrap in PersistenceError for structured logging
      const persistenceError = new PersistenceError('Failed to store error.agent event', {
        table: 'events',
        operation: 'write',
        context: {
          sessionId: options.sessionId,
          eventType: 'error.agent',
          originalError: error instanceof Error ? error.message : String(error),
        },
        cause: storeErr instanceof Error ? storeErr : undefined,
      });
      logger.error('Persistence error during error handling', persistenceError.toStructuredLog());

      // Emit error event so callers can observe storage failures
      this.config.emit('agent_event', {
        type: 'error.persistence',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        runId: options.runId,
        data: {
          message: 'Failed to persist error event',
          eventType: 'error.agent',
          code: persistenceError.code,
        },
      });
    }

    // Notify caller of error
    if (options.onEvent) {
      options.onEvent({
        type: 'error',
        sessionId: options.sessionId,
        timestamp: new Date().toISOString(),
        runId: options.runId,
        data: { message: error instanceof Error ? error.message : 'Unknown error' },
      });
    }

    // Emit agent.complete for error case
    this.emitAgentComplete(options.sessionId, false, error instanceof Error ? error.message : String(error), options.runId);

    throw error;
  }

  // ===========================================================================
  // Event Emission
  // ===========================================================================

  /**
   * Emit turn completion events.
   */
  private emitTurnComplete(
    sessionId: string,
    runResult: RunResult,
    onEvent?: (event: AgentEvent) => void,
    runId?: string
  ): void {
    const event = {
      type: 'turn_complete',
      sessionId,
      timestamp: new Date().toISOString(),
      runId,
      data: runResult,
    };

    this.config.emit('agent_turn', event);

    if (onEvent) {
      onEvent(event as AgentEvent);
    }
  }

  /**
   * Emit agent.complete event.
   * Called after all linearized events are persisted.
   */
  private emitAgentComplete(sessionId: string, success: boolean, error?: string, runId?: string): void {
    this.config.emit('agent_event', {
      type: 'agent.complete',
      sessionId,
      timestamp: new Date().toISOString(),
      runId,
      data: {
        success,
        error,
      },
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an AgentRunner instance.
 */
export function createAgentRunner(config: AgentRunnerConfig): AgentRunner {
  return new AgentRunner(config);
}
