/**
 * @fileoverview TronAgent - Core agent implementation
 *
 * The main agent class that orchestrates:
 * - LLM communication via provider
 * - Tool execution
 * - Hook system
 * - State management
 * - Event emission
 *
 * This is the refactored version that delegates to specialized modules:
 * - EventEmitter: Event handling and listener management
 * - ToolExecutor: Tool execution with hook support
 * - StreamProcessor: Provider stream processing
 * - CompactionHandler: Context compaction management
 * - TurnRunner: Single turn execution orchestration
 */

import { randomUUID } from 'crypto';
import type {
  Message,
  TronTool,
  TronEvent,
} from '@core/types/index.js';
import {
  createProvider,
  detectProviderFromModel,
  type Provider,
  type ProviderType,
  type UnifiedAuth,
} from '@llm/providers/index.js';
import type { GoogleOAuthEndpoint } from '@infrastructure/auth/index.js';
import { HookEngine } from '@capabilities/extensions/hooks/engine.js';
import { ContextManager, createContextManager } from '@context/context-manager.js';
import type { Summarizer } from '@context/summarizer.js';
import type {
  HookDefinition,
  HookType,
  HookResult,
  AnyHookContext,
  SessionStartHookContext,
  SessionEndHookContext,
  UserPromptSubmitHookContext,
  StopHookContext,
} from '@capabilities/extensions/hooks/types.js';
import { createLogger, updateLoggingContext } from '@infrastructure/logging/index.js';
import type {
  AgentConfig,
  AgentOptions,
  AgentState,
  TurnResult,
  RunResult,
} from './types.js';
import { AgentEventEmitter, createEventEmitter } from './event-emitter.js';
import { AgentToolExecutor, createToolExecutor } from './tool-executor.js';
import { AgentStreamProcessor, createStreamProcessor } from './stream-processor.js';
import { AgentCompactionHandler, createCompactionHandler } from './compaction-handler.js';
import { AgentTurnRunner, createTurnRunner } from './turn-runner.js';
import { MAX_TURNS_DEFAULT } from '../constants.js';

const logger = createLogger('agent');

export class TronAgent {
  readonly sessionId: string;
  private config: AgentConfig;
  private provider: Provider;
  private providerType: ProviderType;
  private tools: Map<string, TronTool>;
  private hookEngine: HookEngine;
  private contextManager: ContextManager;
  private currentTurn: number;
  private tokenUsage: { inputTokens: number; outputTokens: number };
  private isRunning: boolean;
  private abortController: AbortController | null;
  readonly workingDirectory: string;

  /** Per-run context — set via setters or run(content, runContext), consumed during turns */
  private currentRunContext: import('./types.js').RunContext = {};

  // Extracted modules
  private eventEmitter: AgentEventEmitter;
  private toolExecutor: AgentToolExecutor;
  private streamProcessor: AgentStreamProcessor;
  private compactionHandler: AgentCompactionHandler;
  private turnRunner: AgentTurnRunner;

  constructor(config: AgentConfig, options: AgentOptions = {}) {
    this.sessionId = options.sessionId ?? `sess_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    this.config = config;

    // Detect provider type from model if not specified
    this.providerType = config.provider.type ?? detectProviderFromModel(config.provider.model);

    // Create provider using factory
    this.provider = createProvider({
      type: this.providerType,
      model: config.provider.model,
      auth: config.provider.auth,
      maxTokens: config.maxTokens,
      temperature: config.temperature,
      baseURL: config.provider.baseURL,
      thinkingBudget: config.provider.thinkingBudget ?? config.thinkingBudget,
      googleEndpoint: config.provider.googleEndpoint,
    });

    this.tools = new Map();
    for (const tool of config.tools) {
      this.tools.set(tool.name, tool);
    }

    this.hookEngine = new HookEngine();
    this.workingDirectory = options.workingDirectory ?? process.cwd();

    // Create ContextManager for all context operations
    this.contextManager = createContextManager({
      model: config.provider.model,
      systemPrompt: config.systemPrompt,
      workingDirectory: this.workingDirectory,
      tools: Array.from(this.tools.values()).map(tool => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
      })),
      compaction: config.compaction,
    });

    this.currentTurn = 0;
    this.tokenUsage = { inputTokens: 0, outputTokens: 0 };
    this.isRunning = false;
    this.abortController = null;

    // Initialize extracted modules
    this.eventEmitter = createEventEmitter();

    this.toolExecutor = createToolExecutor({
      tools: this.tools,
      hookEngine: this.hookEngine,
      contextManager: this.contextManager,
      eventEmitter: this.eventEmitter,
      sessionId: this.sessionId,
      getAbortSignal: () => this.abortController?.signal,
    });

    this.streamProcessor = createStreamProcessor({
      eventEmitter: this.eventEmitter,
      sessionId: this.sessionId,
      getAbortSignal: () => this.abortController?.signal,
    });

    this.compactionHandler = createCompactionHandler({
      contextManager: this.contextManager,
      eventEmitter: this.eventEmitter,
      sessionId: this.sessionId,
      hookEngine: this.hookEngine,
    });

    this.turnRunner = createTurnRunner({
      provider: this.provider,
      contextManager: this.contextManager,
      eventEmitter: this.eventEmitter,
      toolExecutor: this.toolExecutor,
      streamProcessor: this.streamProcessor,
      compactionHandler: this.compactionHandler,
      sessionId: this.sessionId,
      config: {
        maxTokens: config.maxTokens,
        temperature: config.temperature,
        enableThinking: config.enableThinking,
        thinkingBudget: config.thinkingBudget,
        stopSequences: config.stopSequences,
      },
      getAbortSignal: () => this.abortController?.signal,
      tools: this.tools,
      workingDirectory: this.workingDirectory,
    });

    logger.info('TronAgent initialized', {
      sessionId: this.sessionId,
      provider: this.providerType,
      model: config.provider.model,
      toolCount: this.tools.size,
    });
  }

  // ===========================================================================
  // Model and Provider Management
  // ===========================================================================

  /**
   * Get current provider type
   */
  getProviderType(): ProviderType {
    return this.providerType;
  }

  /**
   * Get current model
   */
  getModel(): string {
    return this.provider.model;
  }

  /**
   * Get current reasoning level (from active run context).
   */
  getReasoningLevel(): import('./types.js').ReasoningLevel | undefined {
    return this.currentRunContext.reasoningLevel;
  }

  /**
   * Switch to a different model (preserves session context)
   * For Google models, auth may include endpoint and projectId fields.
   */
  switchModel(model: string, providerType?: ProviderType, auth?: UnifiedAuth & { endpoint?: GoogleOAuthEndpoint }): void {
    if (this.isRunning) {
      throw new Error('Cannot switch model while agent is running');
    }

    logger.info('Switching model', {
      sessionId: this.sessionId,
      previousModel: this.config.provider.model,
      newModel: model,
      messageCountPreserved: this.contextManager.getMessages().length,
      authProvided: !!auth,
    });

    const newProviderType = providerType ?? detectProviderFromModel(model);
    const effectiveAuth = auth ?? this.config.provider.auth;

    // Extract Google-specific endpoint if present in auth
    const googleEndpoint = auth?.endpoint ?? this.config.provider.googleEndpoint;

    // Create new provider
    this.provider = createProvider({
      type: newProviderType,
      model,
      auth: effectiveAuth,
      maxTokens: this.config.maxTokens,
      temperature: this.config.temperature,
      baseURL: this.config.provider.baseURL,
      thinkingBudget: this.config.provider.thinkingBudget ?? this.config.thinkingBudget,
      googleEndpoint,
    });

    this.providerType = newProviderType;

    // Update config
    this.config.provider.model = model;
    this.config.provider.type = newProviderType;
    if (auth) {
      this.config.provider.auth = auth;
    }

    // Update ContextManager with new model
    this.contextManager.switchModel(model);

    // Recreate turn runner with new provider
    this.turnRunner = createTurnRunner({
      provider: this.provider,
      contextManager: this.contextManager,
      eventEmitter: this.eventEmitter,
      toolExecutor: this.toolExecutor,
      streamProcessor: this.streamProcessor,
      compactionHandler: this.compactionHandler,
      sessionId: this.sessionId,
      config: {
        maxTokens: this.config.maxTokens,
        temperature: this.config.temperature,
        enableThinking: this.config.enableThinking,
        thinkingBudget: this.config.thinkingBudget,
        stopSequences: this.config.stopSequences,
      },
      getAbortSignal: () => this.abortController?.signal,
      tools: this.tools,
      workingDirectory: this.workingDirectory,
    });

    logger.info('Model switched', {
      sessionId: this.sessionId,
      previousModel: this.config.provider.model,
      newModel: model,
      provider: newProviderType,
    });
  }

  // ===========================================================================
  // Compaction and Summarizer
  // ===========================================================================

  /**
   * Set the summarizer for auto-compaction.
   */
  setSummarizer(summarizer: Summarizer): void {
    this.compactionHandler.setSummarizer(summarizer);
  }

  /**
   * Get the current summarizer (if set).
   */
  getSummarizer(): Summarizer | null {
    return this.compactionHandler.getSummarizer();
  }

  /**
   * Enable or disable auto-compaction.
   */
  setAutoCompaction(enabled: boolean): void {
    this.compactionHandler.setAutoCompaction(enabled);
  }

  /**
   * Check if auto-compaction is available
   */
  canAutoCompact(): boolean {
    return this.compactionHandler.canAutoCompact();
  }

  /**
   * Attempt compaction using the agent's configured LLM summarizer.
   */
  async attemptCompaction(reason: 'pre_turn_guardrail' | 'threshold_exceeded' | 'manual' = 'manual'): Promise<{
    success: boolean;
    tokensBefore?: number;
    tokensAfter?: number;
    error?: string;
  }> {
    return this.compactionHandler.attemptCompaction(reason);
  }

  // ===========================================================================
  // Skill and Rules Context
  // ===========================================================================

  /**
   * Set rules content from AGENTS.md / CLAUDE.md hierarchy.
   */
  setRulesContent(rulesContent: string | undefined): void {
    this.contextManager.setRulesContent(rulesContent);
  }

  setMemoryContent(memoryContent: string | undefined): void {
    this.contextManager.setMemoryContent(memoryContent);
  }

  // ===========================================================================
  // State Access
  // ===========================================================================

  /**
   * Get current agent state
   */
  getState(): AgentState {
    return {
      sessionId: this.sessionId,
      messages: this.contextManager.getMessages(),
      currentTurn: this.currentTurn,
      tokenUsage: { ...this.tokenUsage },
      isRunning: this.isRunning,
    };
  }

  /**
   * Get the context manager for advanced context operations
   */
  getContextManager(): ContextManager {
    return this.contextManager;
  }

  /**
   * Add a message to the conversation
   */
  addMessage(message: Message): void {
    this.contextManager.addMessage(message);
    logger.debug('Message added', { role: message.role, sessionId: this.sessionId });
  }

  /**
   * Clear all messages
   */
  clearMessages(): void {
    this.contextManager.setMessages([]);
    this.currentTurn = 0;
    logger.debug('Messages cleared', { sessionId: this.sessionId });
  }

  // ===========================================================================
  // Tool Management
  // ===========================================================================

  /**
   * Get a tool by name
   */
  getTool(name: string): TronTool | undefined {
    return this.tools.get(name);
  }

  /**
   * Register a new tool
   */
  registerTool(tool: TronTool): void {
    this.tools.set(tool.name, tool);
    logger.info('Tool registered', { name: tool.name, sessionId: this.sessionId });
  }

  // ===========================================================================
  // Hook Management
  // ===========================================================================

  /**
   * Register a hook
   */
  registerHook(hook: HookDefinition): void {
    this.hookEngine.register(hook);
  }

  /**
   * Number of background hooks still running (compaction, memory ledger, etc.).
   */
  getPendingBackgroundHookCount(): number {
    return this.hookEngine.getPendingBackgroundCount();
  }

  /**
   * Wait for all pending background hooks to complete.
   * Used by agent-controller to drain hooks before starting the next run.
   */
  waitForBackgroundHooks(timeoutMs?: number): Promise<void> {
    return this.hookEngine.waitForBackgroundHooks(timeoutMs);
  }

  /**
   * Execute a lifecycle hook with proper event emission.
   * Uses HookEngine.executeWithEvents() for centralized hook lifecycle management.
   */
  private async executeLifecycleHook(
    hookType: HookType,
    data: Record<string, unknown>
  ): Promise<HookResult> {
    const context = this.buildHookContext(hookType, data);
    return this.hookEngine.executeWithEvents(hookType, context, this.eventEmitter);
  }

  /**
   * Build a typed hook context based on hook type
   */
  private buildHookContext(hookType: HookType, data: Record<string, unknown>): AnyHookContext {
    const base = {
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      data,
    };

    switch (hookType) {
      case 'SessionStart':
        return {
          ...base,
          hookType: 'SessionStart',
          workingDirectory: (data.workingDirectory as string) ?? this.workingDirectory,
        } satisfies SessionStartHookContext;

      case 'SessionEnd':
        return {
          ...base,
          hookType: 'SessionEnd',
          messageCount: (data.messageCount as number) ?? this.contextManager.getMessages().length,
          toolCallCount: (data.toolCallCount as number) ?? this.currentTurn,
        } satisfies SessionEndHookContext;

      case 'UserPromptSubmit':
        return {
          ...base,
          hookType: 'UserPromptSubmit',
          prompt: data.prompt as string,
        } satisfies UserPromptSubmitHookContext;

      case 'Stop':
        return {
          ...base,
          hookType: 'Stop',
          stopReason: data.stopReason as string,
          finalMessage: data.finalMessage as string | undefined,
        } satisfies StopHookContext;

      default:
        // For other hook types, return base context with hookType
        // This handles cases where we don't have a specific context builder
        return {
          ...base,
          hookType,
        } as AnyHookContext;
    }
  }

  // ===========================================================================
  // Event Management
  // ===========================================================================

  /**
   * Add event listener
   */
  onEvent(listener: (event: TronEvent) => void): void {
    this.eventEmitter.addListener(listener);
  }

  /**
   * Emit an event to all listeners
   */
  emit(event: TronEvent): void {
    this.eventEmitter.emit(event);
  }

  // ===========================================================================
  // Abort/Interrupt Handling
  // ===========================================================================

  /**
   * Abort the current run
   */
  abort(): void {
    if (this.abortController) {
      this.abortController.abort();
    }

    // Emit interrupted event with context
    this.emit({
      type: 'agent_interrupted',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      turn: this.currentTurn,
      partialContent: this.streamProcessor.getStreamingContent() || undefined,
      activeTool: this.toolExecutor.getActiveTool() || undefined,
    });

    this.isRunning = false;
    logger.info('Agent aborted', {
      sessionId: this.sessionId,
      turn: this.currentTurn,
      hasPartialContent: !!this.streamProcessor.getStreamingContent(),
      activeTool: this.toolExecutor.getActiveTool(),
    });
  }

  /**
   * Check if the agent was interrupted
   */
  isInterrupted(): boolean {
    return this.abortController?.signal.aborted ?? false;
  }

  /**
   * Get partial streaming content (useful after interrupt)
   */
  getPartialContent(): string {
    return this.streamProcessor.getStreamingContent();
  }

  // ===========================================================================
  // Turn and Run Execution
  // ===========================================================================

  /**
   * Run a single turn (send to LLM, get response, execute tools if needed)
   */
  async turn(): Promise<TurnResult> {
    if (this.isRunning) {
      return { success: false, error: 'Agent is already running' };
    }

    this.isRunning = true;
    this.currentTurn++;
    this.abortController = new AbortController();

    // Update logging context with current turn number
    updateLoggingContext({ turn: this.currentTurn });

    const result = await this.turnRunner.execute({
      turn: this.currentTurn,
      reasoningLevel: this.currentRunContext.reasoningLevel,
      skillContext: this.currentRunContext.skillContext,
      subagentResultsContext: this.currentRunContext.subagentResults,
      todoContext: this.currentRunContext.todoContext,
    });

    // Clear subagent results after consuming (one-time injection)
    this.currentRunContext.subagentResults = undefined;

    // Update token usage
    if (result.tokenUsage) {
      this.tokenUsage.inputTokens += result.tokenUsage.inputTokens;
      this.tokenUsage.outputTokens += result.tokenUsage.outputTokens;
    }

    this.isRunning = false;
    return result;
  }

  /**
   * Run agent until completion or max turns
   * @param userContent - User message as string or array of content blocks
   * @param runContext - Per-run context (skills, subagent results, todos, reasoning level).
   *                     Consumed for this run only, then cleared.
   */
  async run(
    userContent: string | import('../../core/types/index.js').UserContent[],
    runContext?: import('./types.js').RunContext,
  ): Promise<RunResult> {
    // Set run context for this execution (cleared in finally)
    if (runContext) {
      this.currentRunContext = { ...runContext };
    }

    try {
      this.emit({
        type: 'agent_start',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
      });

      // === SessionStart Hook ===
      await this.executeLifecycleHook('SessionStart', {
        workingDirectory: this.workingDirectory,
      });

      // Add user message
      this.addMessage({ role: 'user', content: userContent });

      // === UserPromptSubmit Hook (can block) ===
      const promptText = typeof userContent === 'string'
        ? userContent
        : userContent.map(c => ('text' in c ? c.text : '')).join('\n');

      const promptResult = await this.executeLifecycleHook('UserPromptSubmit', {
        prompt: promptText,
      });

      if (promptResult.action === 'block') {
        await this.executeLifecycleHook('Stop', { stopReason: 'blocked', finalMessage: promptResult.reason });
        await this.executeLifecycleHook('SessionEnd', { messageCount: 1, toolCallCount: 0 });

        this.emit({
          type: 'agent_end',
          sessionId: this.sessionId,
          timestamp: new Date().toISOString(),
          error: promptResult.reason ?? 'Prompt blocked by hook',
        });

        return {
          success: false,
          messages: this.contextManager.getMessages(),
          turns: 0,
          totalTokenUsage: this.tokenUsage,
          error: promptResult.reason ?? 'Prompt blocked by hook',
        };
      }

      const maxTurns = this.config.maxTurns ?? MAX_TURNS_DEFAULT;
      let lastResult: TurnResult | undefined;

      while (this.currentTurn < maxTurns) {
        lastResult = await this.turn();

        if (!lastResult.success) {
          if (lastResult.interrupted) {
            // === Stop Hook (interrupted) ===
            await this.executeLifecycleHook('Stop', { stopReason: 'interrupted' });
            await this.executeLifecycleHook('SessionEnd', {
              messageCount: this.contextManager.getMessages().length,
              toolCallCount: this.currentTurn,
            });

            return {
              success: false,
              messages: this.contextManager.getMessages(),
              turns: this.currentTurn,
              totalTokenUsage: this.tokenUsage,
              error: lastResult.error,
              interrupted: true,
              partialContent: lastResult.partialContent,
            };
          }

          // === Stop Hook (error) ===
          await this.executeLifecycleHook('Stop', {
            stopReason: 'error',
            finalMessage: lastResult.error,
          });
          await this.executeLifecycleHook('SessionEnd', {
            messageCount: this.contextManager.getMessages().length,
            toolCallCount: this.currentTurn,
          });

          this.emit({
            type: 'agent_end',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            error: lastResult.error,
          });

          return {
            success: false,
            messages: this.contextManager.getMessages(),
            turns: this.currentTurn,
            totalTokenUsage: this.tokenUsage,
            error: lastResult.error,
          };
        }

        // Stop if no tools were called or a tool requested stop
        if (lastResult.toolCallsExecuted === 0 || lastResult.stopTurnRequested) {
          break;
        }
      }

      // === Stop Hook (success) ===
      await this.executeLifecycleHook('Stop', {
        stopReason: 'completed',
        stoppedReason: lastResult?.stopReason,
      });
      await this.executeLifecycleHook('SessionEnd', {
        messageCount: this.contextManager.getMessages().length,
        toolCallCount: this.currentTurn,
      });

      this.emit({
        type: 'agent_end',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
      });

      return {
        success: true,
        messages: this.contextManager.getMessages(),
        turns: this.currentTurn,
        totalTokenUsage: this.tokenUsage,
        stoppedReason: lastResult?.stopReason,
      };
    } finally {
      // Clear run context to prevent leaking between runs
      this.currentRunContext = {};
    }
  }
}
