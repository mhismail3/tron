/**
 * @fileoverview TronAgent - Core agent implementation
 *
 * The main agent class that orchestrates:
 * - LLM communication via provider
 * - Tool execution
 * - Hook system
 * - State management
 * - Event emission
 */

import { randomUUID } from 'crypto';
import { appendFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import type {
  Message,
  AssistantMessage,
  ToolResultMessage,
  TronTool,
  TronEvent,
  TronToolResult,
  Context,
  ToolCall,
  TextContent,
  UserContent,
} from '../types/index.js';
import {
  createProvider,
  detectProviderFromModel,
  type Provider,
  type ProviderType,
  type UnifiedAuth,
} from '../providers/index.js';
import { HookEngine } from '../hooks/engine.js';
import { ContextManager, createContextManager } from '../context/context-manager.js';
import type { Summarizer } from '../context/summarizer.js';
import type { HookDefinition, PreToolHookContext, PostToolHookContext } from '../hooks/types.js';
import { createLogger } from '../logging/logger.js';
import { getTronDataDir } from '../settings/loader.js';
import { calculateCost } from '../usage/index.js';
import type {
  AgentConfig,
  AgentOptions,
  AgentState,
  TurnResult,
  RunResult,
  ToolExecutionRequest,
  ToolExecutionResponse,
} from './types.js';

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
  private eventListeners: ((event: TronEvent) => void)[];
  readonly workingDirectory: string;
  /** Tracks partial content during streaming for interrupt recovery */
  private streamingContent: string = '';
  /** Tracks the currently executing tool for interrupt reporting */
  private activeTool: string | null = null;
  /** Current reasoning level for OpenAI Codex models */
  private currentReasoningLevel: 'low' | 'medium' | 'high' | 'xhigh' | undefined;
  /** Summarizer for auto-compaction */
  private summarizer: Summarizer | null = null;
  /** JSONL log file path for turn metadata */
  private turnLogPath: string;
  /** Whether auto-compaction is enabled */
  private autoCompactionEnabled: boolean = true;

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
      organization: config.provider.organization,
    });

    this.tools = new Map();
    for (const tool of config.tools) {
      this.tools.set(tool.name, tool);
    }

    this.hookEngine = new HookEngine();
    this.workingDirectory = options.workingDirectory ?? process.cwd();

    // Create ContextManager for all context operations
    // Pass working directory so ContextManager can build provider-specific system prompts
    this.contextManager = createContextManager({
      model: config.provider.model,
      systemPrompt: config.systemPrompt,
      workingDirectory: this.workingDirectory,
      tools: Array.from(this.tools.values()).map(tool => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
      })),
    });

    this.currentTurn = 0;
    this.tokenUsage = { inputTokens: 0, outputTokens: 0 };
    this.isRunning = false;
    this.abortController = null;
    this.eventListeners = [];

    // Initialize turn log path for JSONL debugging
    const tronDataDir = getTronDataDir();
    const logsDir = join(tronDataDir, 'logs');
    if (!existsSync(logsDir)) {
      mkdirSync(logsDir, { recursive: true });
    }
    this.turnLogPath = join(logsDir, `turns-${this.sessionId}.jsonl`);

    logger.info('TronAgent initialized', {
      sessionId: this.sessionId,
      provider: this.providerType,
      model: config.provider.model,
      toolCount: this.tools.size,
    });
  }

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
   * Set reasoning level for OpenAI Codex models.
   * Call this before run() to set the reasoning effort.
   */
  setReasoningLevel(level: 'low' | 'medium' | 'high' | 'xhigh' | undefined): void {
    this.currentReasoningLevel = level;
  }

  /**
   * Get current reasoning level
   */
  getReasoningLevel(): 'low' | 'medium' | 'high' | 'xhigh' | undefined {
    return this.currentReasoningLevel;
  }

  /**
   * Set the summarizer for auto-compaction.
   * When set, the agent will automatically compact context when thresholds are hit.
   */
  setSummarizer(summarizer: Summarizer): void {
    this.summarizer = summarizer;
    logger.info('Summarizer configured', { sessionId: this.sessionId });
  }

  /**
   * Enable or disable auto-compaction.
   * When enabled and a summarizer is set, context will be compacted automatically.
   */
  setAutoCompaction(enabled: boolean): void {
    this.autoCompactionEnabled = enabled;
    logger.info('Auto-compaction toggled', {
      sessionId: this.sessionId,
      enabled,
    });
  }

  /**
   * Check if auto-compaction is available (has summarizer and is enabled)
   */
  canAutoCompact(): boolean {
    return this.autoCompactionEnabled && this.summarizer !== null;
  }

  /**
   * Get the path to the turn metadata JSONL log
   */
  getTurnLogPath(): string {
    return this.turnLogPath;
  }

  /**
   * Switch to a different model (preserves session context)
   * @param model - The model ID to switch to
   * @param providerType - Optional explicit provider type (auto-detected if not provided)
   * @param auth - Optional new auth credentials (required when switching between providers)
   */
  switchModel(model: string, providerType?: ProviderType, auth?: UnifiedAuth): void {
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

    // Create new provider with appropriate auth
    this.provider = createProvider({
      type: newProviderType,
      model,
      auth: effectiveAuth,
      maxTokens: this.config.maxTokens,
      temperature: this.config.temperature,
      baseURL: this.config.provider.baseURL,
      thinkingBudget: this.config.provider.thinkingBudget ?? this.config.thinkingBudget,
      organization: this.config.provider.organization,
    });

    this.providerType = newProviderType;

    logger.info('Model switched', {
      sessionId: this.sessionId,
      previousModel: this.config.provider.model,
      newModel: model,
      provider: newProviderType,
    });

    // Update config (including auth if new auth was provided)
    this.config.provider.model = model;
    this.config.provider.type = newProviderType;
    if (auth) {
      this.config.provider.auth = auth;
    }

    // Update ContextManager with new model
    this.contextManager.switchModel(model);
  }

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

  /**
   * Register a hook
   */
  registerHook(hook: HookDefinition): void {
    this.hookEngine.register(hook);
  }

  /**
   * Add event listener
   */
  onEvent(listener: (event: TronEvent) => void): void {
    this.eventListeners.push(listener);
  }

  /**
   * Emit an event to all listeners
   */
  emit(event: TronEvent): void {
    for (const listener of this.eventListeners) {
      try {
        listener(event);
      } catch (error) {
        logger.error('Event listener error', error instanceof Error ? error : new Error(String(error)));
      }
    }
  }

  /**
   * Abort the current run
   * Emits agent_interrupted event and preserves partial content
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
      partialContent: this.streamingContent || undefined,
      activeTool: this.activeTool || undefined,
    });

    this.isRunning = false;
    logger.info('Agent aborted', {
      sessionId: this.sessionId,
      turn: this.currentTurn,
      hasPartialContent: !!this.streamingContent,
      activeTool: this.activeTool,
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
    return this.streamingContent;
  }

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
    this.streamingContent = ''; // Reset streaming content for new turn
    this.activeTool = null;

    const turnStartTime = Date.now();

    // ==========================================================================
    // PRE-TURN GUARDRAIL: Validate context before proceeding
    // ==========================================================================
    const validation = this.contextManager.canAcceptTurn({ estimatedResponseTokens: 4000 });

    if (!validation.canProceed) {
      // Context would exceed limit - try auto-compaction if available
      if (this.canAutoCompact() && this.summarizer) {
        logger.info('Pre-turn guardrail triggered - attempting auto-compaction', {
          sessionId: this.sessionId,
          turn: this.currentTurn,
          currentTokens: this.contextManager.getCurrentTokens(),
          contextLimit: this.contextManager.getContextLimit(),
        });

        this.emit({
          type: 'compaction_start',
          sessionId: this.sessionId,
          timestamp: new Date().toISOString(),
          reason: 'pre_turn_guardrail',
          tokensBefore: this.contextManager.getCurrentTokens(),
        });

        try {
          const result = await this.contextManager.executeCompaction({
            summarizer: this.summarizer,
          });

          this.emit({
            type: 'compaction_complete',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            success: result.success,
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            compressionRatio: result.compressionRatio,
            reason: 'pre_turn_guardrail',
          });

          if (!result.success) {
            this.isRunning = false;
            return {
              success: false,
              error: 'Context limit exceeded and auto-compaction failed',
            };
          }

          logger.info('Auto-compaction successful', {
            sessionId: this.sessionId,
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
          });
        } catch (error) {
          this.isRunning = false;
          const errorMessage = error instanceof Error ? error.message : String(error);
          logger.error('Auto-compaction failed', { error: errorMessage });
          return {
            success: false,
            error: `Context limit exceeded and compaction failed: ${errorMessage}`,
          };
        }
      } else {
        // No summarizer - cannot auto-compact
        this.isRunning = false;
        return {
          success: false,
          error: 'Context limit exceeded. Enable auto-compaction or clear messages.',
        };
      }
    } else if (validation.needsCompaction && this.canAutoCompact()) {
      // Context is getting high but still ok - log warning for post-turn hook to handle
      logger.debug('Context approaching threshold', {
        sessionId: this.sessionId,
        turn: this.currentTurn,
        thresholdLevel: this.contextManager.getSnapshot().thresholdLevel,
      });
    }

    this.emit({
      type: 'turn_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      turn: this.currentTurn,
    });

    try {
      // Get messages from ContextManager
      const messages = this.contextManager.getMessages();

      // Build context using ContextManager's provider-aware system prompt
      const context: Context = {
        messages,
        systemPrompt: this.contextManager.getSystemPrompt(),
        tools: Array.from(this.tools.values()).map(tool => ({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        })),
        workingDirectory: this.workingDirectory,
      };

      // Debug: Log context being sent to provider
      logger.debug('Building context for turn', {
        sessionId: this.sessionId,
        turn: this.currentTurn,
        messageCount: messages.length,
        messageRoles: messages.map(m => m.role),
        providerType: this.providerType,
        systemPromptLength: context.systemPrompt?.length ?? 0,
        systemPromptPreview: context.systemPrompt?.substring(0, 100),
        workingDirectory: this.workingDirectory,
        hasToolClarification: this.contextManager.requiresToolClarification(),
      });

      // Stream response
      let assistantMessage: AssistantMessage | undefined;
      let toolCalls: ToolCall[] = [];
      let accumulatedText = '';
      let stopReason: string | undefined;

      for await (const event of this.provider.stream(context, {
        maxTokens: this.config.maxTokens,
        temperature: this.config.temperature,
        enableThinking: this.config.enableThinking,
        thinkingBudget: this.config.thinkingBudget,
        stopSequences: this.config.stopSequences,
        reasoningEffort: this.currentReasoningLevel,
      })) {
        if (this.abortController?.signal.aborted) {
          throw new Error('Aborted');
        }

        // Emit stream events
        if (event.type === 'text_delta') {
          accumulatedText += event.delta;
          this.streamingContent += event.delta; // Track for interrupt recovery
          this.emit({
            type: 'message_update',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            content: event.delta,
          });
        }

        // Capture tool calls as they complete (more reliable than final message)
        if (event.type === 'toolcall_end') {
          toolCalls.push(event.toolCall);
        }

        if (event.type === 'done') {
          assistantMessage = event.message;
          stopReason = event.stopReason;

          // Also check final message for any tool calls we might have missed
          for (const content of assistantMessage.content) {
            if (content.type === 'tool_use') {
              // Only add if not already captured via streaming
              if (!toolCalls.some(tc => tc.id === content.id)) {
                toolCalls.push(content);
              }
            }
          }
        }

        if (event.type === 'error') {
          throw event.error;
        }

        // Handle retry events - emit for TUI to display status
        if (event.type === 'retry') {
          logger.info('Retrying after rate limit', {
            attempt: event.attempt,
            maxRetries: event.maxRetries,
            delayMs: event.delayMs,
            category: event.error.category,
          });
          // Emit proper retry event for TUI handling
          this.emit({
            type: 'api_retry',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            attempt: event.attempt,
            maxRetries: event.maxRetries,
            delayMs: event.delayMs,
            errorCategory: event.error.category,
            errorMessage: event.error.message,
          });
        }
      }

      if (!assistantMessage) {
        throw new Error('No response received');
      }

      // Rebuild assistant message content if it was empty but we have accumulated data
      if (assistantMessage.content.length === 0 && (accumulatedText || toolCalls.length > 0)) {
        const rebuiltContent: (TextContent | ToolCall)[] = [];
        if (accumulatedText) {
          rebuiltContent.push({ type: 'text', text: accumulatedText });
        }
        for (const tc of toolCalls) {
          rebuiltContent.push(tc);
        }
        assistantMessage = {
          ...assistantMessage,
          content: rebuiltContent,
          stopReason: stopReason as AssistantMessage['stopReason'],
        };
      }

      // Update token usage
      if (assistantMessage.usage) {
        this.tokenUsage.inputTokens += assistantMessage.usage.inputTokens;
        this.tokenUsage.outputTokens += assistantMessage.usage.outputTokens;
      }

      // Add assistant message to history via ContextManager
      this.contextManager.addMessage(assistantMessage);

      // Execute tool calls if any
      let toolCallsExecuted = 0;
      let wasInterruptedDuringTools = false;
      if (toolCalls.length > 0) {
        for (const toolCall of toolCalls) {
          // Check for abort BEFORE executing each tool
          if (this.abortController?.signal.aborted) {
            wasInterruptedDuringTools = true;
            logger.info('Abort detected before tool execution', {
              sessionId: this.sessionId,
              toolName: toolCall.name,
            });
            break;
          }

          const result = await this.executeTool({
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            arguments: toolCall.arguments,
          });

          // Add tool result to messages via ContextManager
          const toolResultMessage: ToolResultMessage = {
            role: 'toolResult',
            toolCallId: toolCall.id,
            content: result.result.content,
            isError: result.result.isError,
          };
          this.contextManager.addMessage(toolResultMessage);
          toolCallsExecuted++;

          // Check for abort AFTER tool execution (tool may have been interrupted)
          if (this.abortController?.signal.aborted) {
            wasInterruptedDuringTools = true;
            logger.info('Abort detected after tool execution', {
              sessionId: this.sessionId,
              toolName: toolCall.name,
              wasInterrupted: (result.result.details as Record<string, unknown>)?.interrupted,
            });
            break;
          }

          // Also check if the tool itself reported being interrupted
          const details = result.result.details as Record<string, unknown> | undefined;
          if (details?.interrupted) {
            wasInterruptedDuringTools = true;
            logger.info('Tool reported interruption', {
              sessionId: this.sessionId,
              toolName: toolCall.name,
            });
            break;
          }
        }
      }

      // If interrupted during tool execution, return early
      if (wasInterruptedDuringTools) {
        this.isRunning = false;
        return {
          success: false,
          error: 'Interrupted by user',
          tokenUsage: this.tokenUsage,
          interrupted: true,
          partialContent: this.streamingContent || undefined,
          toolCallsExecuted,
        };
      }

      const turnDuration = Date.now() - turnStartTime;

      // Calculate cost for this turn
      const turnCost = assistantMessage.usage
        ? calculateCost(this.provider.model, {
            inputTokens: assistantMessage.usage.inputTokens,
            outputTokens: assistantMessage.usage.outputTokens,
            cacheReadTokens: assistantMessage.usage.cacheReadTokens,
            cacheCreationTokens: assistantMessage.usage.cacheCreationTokens,
          })
        : undefined;

      this.emit({
        type: 'turn_end',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn: this.currentTurn,
        duration: turnDuration,
        tokenUsage: assistantMessage.usage ? {
          inputTokens: assistantMessage.usage.inputTokens,
          outputTokens: assistantMessage.usage.outputTokens,
          cacheReadTokens: assistantMessage.usage.cacheReadTokens,
          cacheCreationTokens: assistantMessage.usage.cacheCreationTokens,
        } : undefined,
        cost: turnCost?.total,
      });

      // ==========================================================================
      // POST-RESPONSE HOOK: Log turn metadata to JSONL for debugging
      // ==========================================================================
      this.logTurnMetadata({
        turn: this.currentTurn,
        duration: turnDuration,
        success: true,
        toolCallsExecuted,
        tokenUsage: assistantMessage.usage,
        stopReason: assistantMessage.stopReason,
      });

      this.isRunning = false;

      return {
        success: true,
        message: assistantMessage,
        toolCallsExecuted,
        tokenUsage: assistantMessage.usage,
        stopReason: assistantMessage.stopReason,
      };
    } catch (error) {
      this.isRunning = false;
      this.activeTool = null;
      const errorMessage = error instanceof Error ? error.message : String(error);

      // Check if this was an intentional abort/interrupt
      const wasInterrupted = errorMessage === 'Aborted' || this.abortController?.signal.aborted;

      if (wasInterrupted) {
        logger.info('Turn interrupted', {
          sessionId: this.sessionId,
          turn: this.currentTurn,
          hasPartialContent: !!this.streamingContent,
        });

        // Log interrupted turn metadata
        this.logTurnMetadata({
          turn: this.currentTurn,
          duration: Date.now() - turnStartTime,
          success: false,
          toolCallsExecuted: 0,
          error: 'Interrupted by user',
        });

        return {
          success: false,
          error: 'Interrupted by user',
          tokenUsage: this.tokenUsage,
          interrupted: true,
          partialContent: this.streamingContent || undefined,
        };
      }

      logger.error('Turn failed', { error: errorMessage, sessionId: this.sessionId });

      // Log failed turn metadata
      this.logTurnMetadata({
        turn: this.currentTurn,
        duration: Date.now() - turnStartTime,
        success: false,
        toolCallsExecuted: 0,
        error: errorMessage,
      });

      return {
        success: false,
        error: errorMessage,
        tokenUsage: this.tokenUsage,
      };
    }
  }

  /**
   * Run agent until completion or max turns
   * @param userContent - User message as string or array of content blocks (text, images, documents)
   */
  async run(userContent: string | UserContent[]): Promise<RunResult> {
    this.emit({
      type: 'agent_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
    });

    // Add user message
    this.addMessage({ role: 'user', content: userContent });

    const maxTurns = this.config.maxTurns ?? 100;
    let lastResult: TurnResult | undefined;

    while (this.currentTurn < maxTurns) {
      lastResult = await this.turn();

      if (!lastResult.success) {
        // Check if interrupted
        if (lastResult.interrupted) {
          // Don't emit agent_end here - abort() already emitted agent_interrupted
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

      // Continue to next turn if we executed tools (LLM needs to see results)
      // Stop if no tools were called (either pure text response or final answer)
      if (lastResult.toolCallsExecuted === 0) {
        break;
      }
    }

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
  }

  /**
   * Execute a tool with hook support
   */
  private async executeTool(request: ToolExecutionRequest): Promise<ToolExecutionResponse> {
    const startTime = Date.now();
    const tool = this.tools.get(request.toolName);
    this.activeTool = request.toolName; // Track for interrupt reporting

    if (!tool) {
      return {
        toolCallId: request.toolCallId,
        result: {
          content: `Tool not found: ${request.toolName}`,
          isError: true,
        },
        duration: Date.now() - startTime,
      };
    }

    // Execute PreToolUse hooks
    const preContext: PreToolHookContext = {
      hookType: 'PreToolUse',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      data: {},
      toolName: request.toolName,
      toolArguments: request.arguments,
      toolCallId: request.toolCallId,
    };

    const preHooks = this.hookEngine.getHooks('PreToolUse');
    if (preHooks.length > 0) {
      this.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: preHooks.map(h => h.name).join(', '),
        hookEvent: 'PreToolUse',
      });
    }

    const preResult = await this.hookEngine.execute('PreToolUse', preContext);

    if (preHooks.length > 0) {
      this.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: preHooks.map(h => h.name).join(', '),
        hookEvent: 'PreToolUse',
        result: preResult.action,
      });
    }

    if (preResult.action === 'block') {
      return {
        toolCallId: request.toolCallId,
        result: {
          content: `Tool execution blocked: ${preResult.reason}`,
          isError: true,
        },
        duration: Date.now() - startTime,
      };
    }

    // Apply modifications if any
    let args = request.arguments;
    if (preResult.action === 'modify' && preResult.modifications) {
      args = { ...args, ...preResult.modifications };
    }

    this.emit({
      type: 'tool_execution_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      toolName: request.toolName,
      toolCallId: request.toolCallId,
      arguments: args,
    });

    // Execute tool - handle both old (params) and new (toolCallId, params, signal) signatures
    let result: TronToolResult;
    try {
      if (tool.execute.length >= 3) {
        // New signature: (toolCallId, params, signal, onProgress)
        result = await (tool.execute as (id: string, p: Record<string, unknown>, s: AbortSignal) => Promise<TronToolResult>)(
          request.toolCallId,
          args,
          this.abortController?.signal ?? new AbortController().signal
        );
      } else {
        // Old signature: (params)
        result = await (tool.execute as (p: Record<string, unknown>) => Promise<TronToolResult>)(args);
      }
    } catch (error) {
      result = {
        content: `Tool execution error: ${error instanceof Error ? error.message : String(error)}`,
        isError: true,
      };
    }

    const duration = Date.now() - startTime;

    // Convert content to string for compatibility
    let contentString = typeof result.content === 'string'
      ? result.content
      : result.content.map(c => c.type === 'text' ? c.text : '[image]').join('\n');

    // Apply context manager safety net truncation
    const processed = this.contextManager.processToolResult({
      toolCallId: request.toolCallId,
      content: contentString,
    });
    if (processed.truncated) {
      contentString = processed.content;
      logger.info('Tool result truncated by context manager safety net', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        originalSize: processed.originalSize,
        finalSize: contentString.length,
      });
    }

    this.emit({
      type: 'tool_execution_end',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      toolName: request.toolName,
      toolCallId: request.toolCallId,
      duration,
      isError: result.isError,
      result,
    });

    // Execute PostToolUse hooks
    const postContext: PostToolHookContext = {
      hookType: 'PostToolUse',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      data: {},
      toolName: request.toolName,
      toolCallId: request.toolCallId,
      result,
      duration,
    };

    const postHooks = this.hookEngine.getHooks('PostToolUse');
    if (postHooks.length > 0) {
      this.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: postHooks.map(h => h.name).join(', '),
        hookEvent: 'PostToolUse',
      });
    }

    const postResult = await this.hookEngine.execute('PostToolUse', postContext);

    if (postHooks.length > 0) {
      this.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: postHooks.map(h => h.name).join(', '),
        hookEvent: 'PostToolUse',
        result: postResult.action,
      });
    }

    this.activeTool = null; // Clear after execution

    return {
      toolCallId: request.toolCallId,
      result: {
        content: contentString,
        isError: result.isError ?? false,
        details: result.details as Record<string, unknown> | undefined,
      },
      duration,
    };
  }

  /**
   * Log turn metadata to JSONL file for debugging.
   * This is the post-response hook - runs after EVERY response.
   */
  private logTurnMetadata(data: {
    turn: number;
    duration: number;
    success: boolean;
    toolCallsExecuted: number;
    tokenUsage?: { inputTokens: number; outputTokens: number };
    stopReason?: string;
    error?: string;
  }): void {
    try {
      const snapshot = this.contextManager.getSnapshot();

      const record = {
        _meta: {
          sessionId: this.sessionId,
          turn: data.turn,
          timestamp: new Date().toISOString(),
        },
        turn: {
          duration: data.duration,
          success: data.success,
          toolCallsExecuted: data.toolCallsExecuted,
          tokenUsage: data.tokenUsage,
          stopReason: data.stopReason,
          error: data.error,
        },
        context: {
          model: this.contextManager.getModel(),
          provider: this.contextManager.getProviderType(),
          currentTokens: snapshot.currentTokens,
          contextLimit: snapshot.contextLimit,
          usagePercent: snapshot.usagePercent,
          thresholdLevel: snapshot.thresholdLevel,
          messageCount: this.contextManager.getMessages().length,
          breakdown: snapshot.breakdown,
        },
        session: {
          cumulativeInputTokens: this.tokenUsage.inputTokens,
          cumulativeOutputTokens: this.tokenUsage.outputTokens,
        },
      };

      // Append to JSONL file
      const line = JSON.stringify(record) + '\n';
      appendFileSync(this.turnLogPath, line, 'utf-8');

      logger.debug('Turn metadata logged', {
        sessionId: this.sessionId,
        turn: data.turn,
        logPath: this.turnLogPath,
      });
    } catch (error) {
      // Don't fail the turn if logging fails
      logger.error('Failed to log turn metadata', {
        error: error instanceof Error ? error.message : String(error),
        sessionId: this.sessionId,
      });
    }
  }
}
