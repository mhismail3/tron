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
} from '../types/index.js';
import {
  createProvider,
  detectProviderFromModel,
  type Provider,
  type ProviderType,
} from '../providers/index.js';
import { HookEngine } from '../hooks/engine.js';
import type { HookDefinition, PreToolHookContext, PostToolHookContext } from '../hooks/types.js';
import { createLogger } from '../logging/logger.js';
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
  private messages: Message[];
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
    this.messages = [];
    this.currentTurn = 0;
    this.tokenUsage = { inputTokens: 0, outputTokens: 0 };
    this.isRunning = false;
    this.abortController = null;
    this.eventListeners = [];
    this.workingDirectory = options.workingDirectory ?? process.cwd();

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
   * Switch to a different model (preserves session context)
   */
  switchModel(model: string, providerType?: ProviderType): void {
    if (this.isRunning) {
      throw new Error('Cannot switch model while agent is running');
    }

    logger.info('Switching model', {
      sessionId: this.sessionId,
      previousModel: this.config.provider.model,
      newModel: model,
      messageCountPreserved: this.messages.length,
    });

    const newProviderType = providerType ?? detectProviderFromModel(model);

    // Create new provider
    this.provider = createProvider({
      type: newProviderType,
      model,
      auth: this.config.provider.auth,
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

    // Update config
    this.config.provider.model = model;
    this.config.provider.type = newProviderType;
  }

  /**
   * Get current agent state
   */
  getState(): AgentState {
    return {
      sessionId: this.sessionId,
      messages: [...this.messages],
      currentTurn: this.currentTurn,
      tokenUsage: { ...this.tokenUsage },
      isRunning: this.isRunning,
    };
  }

  /**
   * Add a message to the conversation
   */
  addMessage(message: Message): void {
    this.messages.push(message);
    logger.debug('Message added', { role: message.role, sessionId: this.sessionId });
  }

  /**
   * Clear all messages
   */
  clearMessages(): void {
    this.messages = [];
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

    this.emit({
      type: 'turn_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      turn: this.currentTurn,
    });

    try {
      // Build context
      const context: Context = {
        messages: this.messages,
        systemPrompt: this.config.systemPrompt,
        tools: Array.from(this.tools.values()).map(tool => ({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        })),
      };

      // Debug: Log message count being sent to provider
      logger.debug('Building context for turn', {
        sessionId: this.sessionId,
        turn: this.currentTurn,
        messageCount: this.messages.length,
        messageRoles: this.messages.map(m => m.role),
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

      // Add assistant message to history
      this.messages.push(assistantMessage);

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

          // Add tool result to messages
          const toolResultMessage: ToolResultMessage = {
            role: 'toolResult',
            toolCallId: toolCall.id,
            content: result.result.content,
            isError: result.result.isError,
          };
          this.messages.push(toolResultMessage);
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

      this.emit({
        type: 'turn_end',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn: this.currentTurn,
        duration: turnDuration,
        tokenUsage: assistantMessage.usage ? {
          inputTokens: assistantMessage.usage.inputTokens,
          outputTokens: assistantMessage.usage.outputTokens,
        } : undefined,
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

        return {
          success: false,
          error: 'Interrupted by user',
          tokenUsage: this.tokenUsage,
          interrupted: true,
          partialContent: this.streamingContent || undefined,
        };
      }

      logger.error('Turn failed', { error: errorMessage, sessionId: this.sessionId });

      return {
        success: false,
        error: errorMessage,
        tokenUsage: this.tokenUsage,
      };
    }
  }

  /**
   * Run agent until completion or max turns
   */
  async run(userMessage: string): Promise<RunResult> {
    this.emit({
      type: 'agent_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
    });

    // Add user message
    this.addMessage({ role: 'user', content: userMessage });

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
            messages: this.messages,
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
          messages: this.messages,
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
      messages: this.messages,
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
    const contentString = typeof result.content === 'string'
      ? result.content
      : result.content.map(c => c.type === 'text' ? c.text : '[image]').join('\n');

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
}
