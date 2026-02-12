/**
 * @fileoverview Turn Runner Module
 *
 * Orchestrates a single agent turn: validates context, streams response,
 * processes tool calls, and handles compaction. This is the core execution
 * logic extracted from TronAgent.
 */

import type {
  TronTool,
  ToolResultMessage,
  Context,
} from '@core/types/index.js';
import type { Provider } from '@llm/providers/index.js';
import type { ContextManager } from '@context/context-manager.js';
import type {
  TurnRunner as ITurnRunner,
  TurnRunnerDependencies,
  TurnConfig,
  TurnOptions,
  EventEmitter,
  ToolExecutor,
  StreamProcessor,
} from './internal-types.js';
import type { AgentCompactionHandler } from './compaction-handler.js';
import type { TurnResult } from './types.js';
import { calculateCost } from '@infrastructure/usage/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { categorizeError } from '@infrastructure/logging/error-codes.js';
import { COMPACTION_BUFFER_TOKENS } from '../constants.js';

const logger = createLogger('agent:turn');

/**
 * Turn runner implementation
 */
export class AgentTurnRunner implements ITurnRunner {
  private readonly provider: Provider;
  private readonly contextManager: ContextManager;
  private readonly eventEmitter: EventEmitter;
  private readonly toolExecutor: ToolExecutor;
  private readonly streamProcessor: StreamProcessor;
  private readonly compactionHandler: AgentCompactionHandler;
  private readonly sessionId: string;
  private readonly config: TurnConfig;
  private readonly getAbortSignal: () => AbortSignal | undefined;
  private readonly tools: Map<string, TronTool>;
  private readonly workingDirectory: string;

  constructor(deps: TurnRunnerDependencies & {
    tools: Map<string, TronTool>;
    workingDirectory: string;
  }) {
    this.provider = deps.provider;
    this.contextManager = deps.contextManager;
    this.eventEmitter = deps.eventEmitter;
    this.toolExecutor = deps.toolExecutor;
    this.streamProcessor = deps.streamProcessor;
    this.compactionHandler = deps.compactionHandler as AgentCompactionHandler;
    this.sessionId = deps.sessionId;
    this.config = deps.config;
    this.getAbortSignal = deps.getAbortSignal;
    this.tools = deps.tools;
    this.workingDirectory = deps.workingDirectory;
  }

  /**
   * Execute a single turn
   */
  async execute(options: TurnOptions): Promise<TurnResult> {
    const turnStartTime = Date.now();
    const { turn, reasoningLevel, skillContext, subagentResultsContext, taskContext, dynamicRulesContext } = options;

    // Reset streaming content for new turn
    this.streamProcessor.resetStreamingContent();
    this.toolExecutor.clearActiveTool();

    // ==========================================================================
    // PRE-TURN GUARDRAIL: Validate context before proceeding
    // ==========================================================================
    const preTurnResult = await this.validateAndCompactIfNeeded();
    if (!preTurnResult.canProceed) {
      const errorMessage = preTurnResult.error ?? 'Context limit exceeded';

      // Emit turn_failed event for context limit exceeded
      this.eventEmitter.emit({
        type: 'agent.turn_failed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn,
        error: errorMessage,
        code: 'TLIM_CONTEXT',
        category: 'TOKEN_LIMIT',
        recoverable: false,
      });

      return {
        success: false,
        error: errorMessage,
      };
    }

    // Emit turn_start event
    this.eventEmitter.emit({
      type: 'turn_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      turn,
    });

    try {
      // Build context for provider
      const context = this.buildContext(skillContext, subagentResultsContext, taskContext, dynamicRulesContext);

      // Log context being sent
      logger.info('[AGENT] Building context for turn', {
        sessionId: this.sessionId,
        turn,
        messageCount: context.messages.length,
        systemPromptLength: context.systemPrompt?.length ?? 0,
        hasRulesContent: !!context.rulesContent,
        rulesContentLength: context.rulesContent?.length ?? 0,
        hasMemoryContent: !!context.memoryContent,
        memoryContentLength: context.memoryContent?.length ?? 0,
        hasSkillContext: !!skillContext,
        skillContextLength: skillContext?.length ?? 0,
        skillContextPreview: skillContext?.substring(0, 100),
      });

      // Stream response from provider
      // Note: thinkingBudget is used by Anthropic, geminiThinkingBudget is for Gemini 2.5
      // The Google provider expects thinkingBudget, so we pass geminiThinkingBudget as thinkingBudget
      // when using Gemini (the provider will ignore thinkingBudget if it's an Anthropic provider)
      const streamResult = await this.streamProcessor.process(
        this.provider.stream(context, {
          maxTokens: this.config.maxTokens,
          temperature: this.config.temperature,
          enableThinking: this.config.enableThinking,
          thinkingBudget: this.config.geminiThinkingBudget ?? this.config.thinkingBudget,
          stopSequences: this.config.stopSequences,
          effortLevel: reasoningLevel,
          reasoningEffort: reasoningLevel,
          // Gemini 3 thinking level (discrete levels: minimal/low/medium/high)
          thinkingLevel: this.config.thinkingLevel,
        } as Parameters<Provider['stream']>[1])
      );

      const { message: assistantMessage, toolCalls } = streamResult;

      // ==========================================================================
      // CRITICAL: Emit response_complete BEFORE tool execution
      // ==========================================================================
      // Token usage is available now (from the API response). Emit this event
      // so the orchestrator can compute normalizedUsage immediately. This ensures
      // message.assistant events (even for tool-using turns) have token data.
      const tokenUsageForEvent = assistantMessage.usage
        ? {
            inputTokens: assistantMessage.usage.inputTokens,
            outputTokens: assistantMessage.usage.outputTokens,
            cacheReadTokens: assistantMessage.usage.cacheReadTokens,
            cacheCreationTokens: assistantMessage.usage.cacheCreationTokens,
            cacheCreation5mTokens: assistantMessage.usage.cacheCreation5mTokens,
            cacheCreation1hTokens: assistantMessage.usage.cacheCreation1hTokens,
          }
        : undefined;

      logger.info('[TOKEN-FLOW] 1. response_complete emitting', {
        turn,
        hasToolCalls: toolCalls.length > 0,
        toolCallCount: toolCalls.length,
        tokenUsage: tokenUsageForEvent
          ? {
              inputTokens: tokenUsageForEvent.inputTokens,
              outputTokens: tokenUsageForEvent.outputTokens,
              cacheRead: tokenUsageForEvent.cacheReadTokens ?? 0,
              cacheCreation: tokenUsageForEvent.cacheCreationTokens ?? 0,
              cacheCreation5m: tokenUsageForEvent.cacheCreation5mTokens ?? 0,
              cacheCreation1h: tokenUsageForEvent.cacheCreation1hTokens ?? 0,
            }
          : 'MISSING',
      });

      this.eventEmitter.emit({
        type: 'response_complete',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn,
        stopReason: assistantMessage.stopReason ?? 'end_turn',
        tokenUsage: tokenUsageForEvent,
        hasToolCalls: toolCalls.length > 0,
        toolCallCount: toolCalls.length,
      });

      // Add assistant message to history
      this.contextManager.addMessage(assistantMessage);

      // Execute tool calls if any
      const toolResult = await this.executeToolCalls(toolCalls);

      // If interrupted during tool execution, return early
      if (toolResult.interrupted) {
        return {
          success: false,
          error: 'Interrupted by user',
          tokenUsage: assistantMessage.usage,
          interrupted: true,
          partialContent: this.streamProcessor.getStreamingContent() || undefined,
          toolCallsExecuted: toolResult.toolCallsExecuted,
        };
      }

      // Calculate turn metrics
      const turnDuration = Date.now() - turnStartTime;
      const turnCost = assistantMessage.usage
        ? calculateCost(this.provider.model, {
            inputTokens: assistantMessage.usage.inputTokens,
            outputTokens: assistantMessage.usage.outputTokens,
            cacheReadTokens: assistantMessage.usage.cacheReadTokens,
            cacheCreationTokens: assistantMessage.usage.cacheCreationTokens,
          })
        : undefined;

      // Emit turn_end event
      this.eventEmitter.emit({
        type: 'turn_end',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn,
        duration: turnDuration,
        tokenUsage: assistantMessage.usage
          ? {
              inputTokens: assistantMessage.usage.inputTokens,
              outputTokens: assistantMessage.usage.outputTokens,
              cacheReadTokens: assistantMessage.usage.cacheReadTokens,
              cacheCreationTokens: assistantMessage.usage.cacheCreationTokens,
            }
          : undefined,
        cost: turnCost?.total,
        contextLimit: this.contextManager.getContextLimit(),
      });

      // Log turn completion
      this.logTurnCompletion(turn, turnDuration, toolResult.toolCallsExecuted, assistantMessage);

      return {
        success: true,
        message: assistantMessage,
        toolCallsExecuted: toolResult.toolCallsExecuted,
        tokenUsage: assistantMessage.usage,
        stopReason: assistantMessage.stopReason,
        stopTurnRequested: toolResult.stopTurnRequested,
      };
    } catch (error) {
      this.toolExecutor.clearActiveTool();
      const errorMessage = error instanceof Error ? error.message : String(error);

      // Check if this was an intentional abort/interrupt
      const signal = this.getAbortSignal();
      const wasInterrupted = errorMessage === 'Aborted' || signal?.aborted;

      if (wasInterrupted) {
        logger.info('Turn interrupted', {
          sessionId: this.sessionId,
          turn,
          hasPartialContent: !!this.streamProcessor.getStreamingContent(),
        });

        this.logInterruptedTurn(turn, turnStartTime);

        return {
          success: false,
          error: 'Interrupted by user',
          interrupted: true,
          partialContent: this.streamProcessor.getStreamingContent() || undefined,
        };
      }

      // Categorize the error for structured reporting
      const structuredError = categorizeError(error, { sessionId: this.sessionId, turn });

      logger.error('Turn failed', { error: errorMessage, sessionId: this.sessionId });
      this.logFailedTurn(turn, turnStartTime, errorMessage);

      // Emit turn_failed event for iOS visibility
      this.eventEmitter.emit({
        type: 'agent.turn_failed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        turn,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        recoverable: structuredError.retryable,
        partialContent: this.streamProcessor.getStreamingContent() || undefined,
      });

      return {
        success: false,
        error: errorMessage,
      };
    }
  }

  /**
   * Validate context and attempt compaction if needed
   */
  private async validateAndCompactIfNeeded(): Promise<{
    canProceed: boolean;
    error?: string;
  }> {
    const validation = this.compactionHandler.validatePreTurn(COMPACTION_BUFFER_TOKENS);

    if (!validation.canProceed) {
      if (validation.needsCompaction) {
        // Attempt compaction
        const compactionResult = await this.compactionHandler.attemptCompaction('pre_turn_guardrail');

        if (!compactionResult.success) {
          return {
            canProceed: false,
            error: `Context limit exceeded and auto-compaction failed: ${compactionResult.error}`,
          };
        }

        logger.info('Auto-compaction successful', {
          sessionId: this.sessionId,
          tokensBefore: compactionResult.tokensBefore,
          tokensAfter: compactionResult.tokensAfter,
        });

        return { canProceed: true };
      }

      return {
        canProceed: false,
        error: validation.error,
      };
    }

    return { canProceed: true };
  }

  /**
   * Build context for the provider
   */
  private buildContext(skillContext?: string, subagentResultsContext?: string, taskContext?: string, dynamicRulesContext?: string): Context {
    const messages = this.contextManager.getMessages();

    return {
      messages,
      systemPrompt: this.contextManager.getSystemPrompt(),
      tools: Array.from(this.tools.values()).map(tool => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
      })),
      workingDirectory: this.workingDirectory,
      rulesContent: this.contextManager.getRulesContent(),
      memoryContent: this.contextManager.getFullMemoryContent(),
      skillContext,
      subagentResultsContext,
      taskContext,
      dynamicRulesContext,
    };
  }

  /**
   * Execute tool calls and return results
   */
  private async executeToolCalls(toolCalls: import('../../core/types/index.js').ToolCall[]): Promise<{
    toolCallsExecuted: number;
    interrupted: boolean;
    stopTurnRequested: boolean;
  }> {
    let toolCallsExecuted = 0;
    let wasInterruptedDuringTools = false;
    let stopTurnRequested = false;

    if (toolCalls.length === 0) {
      return { toolCallsExecuted: 0, interrupted: false, stopTurnRequested: false };
    }

    // Emit tool_use_batch event with ALL tool_use blocks BEFORE any execution
    // This allows the orchestrator to track all tool intents for linear event ordering
    this.eventEmitter.emit({
      type: 'tool_use_batch',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      toolCalls: toolCalls.map(tc => ({
        id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
      })),
    });

    for (const toolCall of toolCalls) {
      // Check for abort BEFORE executing each tool
      const signal = this.getAbortSignal();
      if (signal?.aborted) {
        wasInterruptedDuringTools = true;
        logger.info('Abort detected before tool execution', {
          sessionId: this.sessionId,
          toolName: toolCall.name,
        });
        break;
      }

      const result = await this.toolExecutor.execute({
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
      this.contextManager.addMessage(toolResultMessage);
      toolCallsExecuted++;

      // Check if tool requested to stop the turn
      if (result.result.stopTurn) {
        stopTurnRequested = true;
        logger.info('Tool requested turn stop', {
          sessionId: this.sessionId,
          toolName: toolCall.name,
        });
      }

      // Check for abort AFTER tool execution
      const signalAfter = this.getAbortSignal();
      if (signalAfter?.aborted) {
        wasInterruptedDuringTools = true;
        logger.info('Abort detected after tool execution', {
          sessionId: this.sessionId,
          toolName: toolCall.name,
        });
        break;
      }

      // Check if the tool reported being interrupted
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

    return {
      toolCallsExecuted,
      interrupted: wasInterruptedDuringTools,
      stopTurnRequested,
    };
  }

  /**
   * Log turn completion at trace level
   */
  private logTurnCompletion(
    turn: number,
    duration: number,
    toolCallsExecuted: number,
    message: import('../../core/types/index.js').AssistantMessage
  ): void {
    const snapshot = this.contextManager.getSnapshot();

    logger.trace('Turn completed', {
      sessionId: this.sessionId,
      turn,
      duration,
      success: true,
      toolCallsExecuted,
      stopReason: message.stopReason,
      tokenUsage: message.usage,
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
    });
  }

  /**
   * Log interrupted turn at trace level
   */
  private logInterruptedTurn(turn: number, startTime: number): void {
    const snapshot = this.contextManager.getSnapshot();

    logger.trace('Turn interrupted', {
      sessionId: this.sessionId,
      turn,
      duration: Date.now() - startTime,
      success: false,
      error: 'Interrupted by user',
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
    });
  }

  /**
   * Log failed turn at trace level
   */
  private logFailedTurn(turn: number, startTime: number, error: string): void {
    const snapshot = this.contextManager.getSnapshot();

    logger.trace('Turn failed', {
      sessionId: this.sessionId,
      turn,
      duration: Date.now() - startTime,
      success: false,
      error,
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
    });
  }
}

/**
 * Create a turn runner instance
 */
export function createTurnRunner(
  deps: TurnRunnerDependencies & {
    tools: Map<string, TronTool>;
    workingDirectory: string;
  }
): AgentTurnRunner {
  return new AgentTurnRunner(deps);
}
