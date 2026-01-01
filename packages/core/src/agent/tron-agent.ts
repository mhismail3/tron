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
import { AnthropicProvider } from '../providers/anthropic.js';
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
  private provider: AnthropicProvider;
  private tools: Map<string, TronTool>;
  private hookEngine: HookEngine;
  private messages: Message[];
  private currentTurn: number;
  private tokenUsage: { inputTokens: number; outputTokens: number };
  private isRunning: boolean;
  private abortController: AbortController | null;
  private eventListeners: ((event: TronEvent) => void)[];
  readonly workingDirectory: string;

  constructor(config: AgentConfig, options: AgentOptions = {}) {
    this.sessionId = options.sessionId ?? `sess_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    this.config = config;
    this.provider = new AnthropicProvider({
      model: config.provider.model,
      auth: config.provider.auth,
      maxTokens: config.maxTokens,
      temperature: config.temperature,
      baseURL: config.provider.baseURL,
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
      model: config.provider.model,
      toolCount: this.tools.size,
    });
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
   */
  abort(): void {
    if (this.abortController) {
      this.abortController.abort();
    }
    this.isRunning = false;
    logger.info('Agent aborted', { sessionId: this.sessionId });
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
      })) {
        if (this.abortController?.signal.aborted) {
          throw new Error('Aborted');
        }

        // Emit stream events
        if (event.type === 'text_delta') {
          accumulatedText += event.delta;
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
      if (toolCalls.length > 0) {
        for (const toolCall of toolCalls) {
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
        }
      }

      const turnDuration = Date.now() - turnStartTime;

      this.emit({
        type: 'turn_end',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn: this.currentTurn,
        duration: turnDuration,
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
      const errorMessage = error instanceof Error ? error.message : String(error);
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

    const preResult = await this.hookEngine.execute('PreToolUse', preContext);

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

    await this.hookEngine.execute('PostToolUse', postContext);

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
