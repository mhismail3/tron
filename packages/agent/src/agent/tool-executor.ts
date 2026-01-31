/**
 * @fileoverview Tool Executor Module
 *
 * Handles tool execution with pre/post hook support.
 * Extracted from TronAgent for better separation of concerns.
 */

import type { TronTool, TronToolResult } from '../types/index.js';
import type { HookEngine } from '../hooks/engine.js';
import type { ContextManager } from '../context/context-manager.js';
import type { PreToolHookContext, PostToolHookContext } from '../hooks/types.js';
import type {
  ToolExecutor as IToolExecutor,
  ToolExecutorDependencies,
  EventEmitter,
} from './internal-types.js';
import type { ToolExecutionRequest, ToolExecutionResponse } from './types.js';
import type { GuardrailEngine } from '../guardrails/engine.js';
import type { SessionState } from '../guardrails/types.js';
import { createLogger, categorizeError } from '../logging/index.js';

const logger = createLogger('agent:tools');

/**
 * Tool executor implementation with hook support
 */
export class AgentToolExecutor implements IToolExecutor {
  private readonly tools: Map<string, TronTool>;
  private readonly hookEngine: HookEngine;
  private readonly contextManager: ContextManager;
  private readonly eventEmitter: EventEmitter;
  private readonly sessionId: string;
  private readonly getAbortSignal: () => AbortSignal | undefined;
  private readonly guardrailEngine: GuardrailEngine | undefined;
  private readonly getSessionState: (() => SessionState | undefined) | undefined;

  private activeTool: string | null = null;

  constructor(deps: ToolExecutorDependencies) {
    this.tools = deps.tools;
    this.hookEngine = deps.hookEngine;
    this.contextManager = deps.contextManager;
    this.eventEmitter = deps.eventEmitter;
    this.sessionId = deps.sessionId;
    this.getAbortSignal = deps.getAbortSignal;
    this.guardrailEngine = deps.guardrailEngine;
    this.getSessionState = deps.getSessionState;
  }

  /**
   * Get the currently executing tool name
   */
  getActiveTool(): string | null {
    return this.activeTool;
  }

  /**
   * Clear the active tool tracking
   */
  clearActiveTool(): void {
    this.activeTool = null;
  }

  /**
   * Execute a tool with pre/post hooks
   */
  async execute(request: ToolExecutionRequest): Promise<ToolExecutionResponse> {
    const startTime = Date.now();
    const tool = this.tools.get(request.toolName);
    this.activeTool = request.toolName;

    // Log tool execution start
    logger.debug('Tool execution starting', {
      toolName: request.toolName,
      toolCallId: request.toolCallId,
      sessionId: this.sessionId,
      hasArguments: Object.keys(request.arguments).length > 0,
    });

    if (!tool) {
      logger.warn('Tool not found', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
        availableTools: Array.from(this.tools.keys()).slice(0, 10),
      });
      this.activeTool = null;
      return {
        toolCallId: request.toolCallId,
        result: {
          content: `Tool not found: ${request.toolName}`,
          isError: true,
        },
        duration: Date.now() - startTime,
      };
    }

    // Evaluate guardrails FIRST (before hooks)
    if (this.guardrailEngine) {
      const sessionState = this.getSessionState?.();
      const evaluation = await this.guardrailEngine.evaluate({
        toolName: request.toolName,
        toolArguments: request.arguments,
        sessionState,
        sessionId: this.sessionId,
        toolCallId: request.toolCallId,
      });

      if (evaluation.blocked) {
        logger.warn('Tool blocked by guardrail', {
          toolName: request.toolName,
          reason: evaluation.blockReason,
          triggeredRules: evaluation.triggeredRules.map(r => r.ruleId),
        });
        this.activeTool = null;
        return {
          toolCallId: request.toolCallId,
          result: {
            content: `Tool execution blocked: ${evaluation.blockReason}`,
            isError: true,
          },
          duration: Date.now() - startTime,
        };
      }

      // Log warnings if any
      if (evaluation.hasWarnings) {
        for (const warning of evaluation.warnings) {
          logger.info('Guardrail warning', { toolName: request.toolName, warning });
        }
      }
    }

    // Execute PreToolUse hooks
    const preHookResult = await this.executePreHooks(request);
    if (preHookResult.blocked) {
      this.activeTool = null;
      return {
        toolCallId: request.toolCallId,
        result: {
          content: `Tool execution blocked: ${preHookResult.reason}`,
          isError: true,
        },
        duration: Date.now() - startTime,
      };
    }

    // Apply modifications from hooks
    const args = preHookResult.modifiedArgs ?? request.arguments;

    // Emit tool execution start event
    this.eventEmitter.emit({
      type: 'tool_execution_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      toolName: request.toolName,
      toolCallId: request.toolCallId,
      arguments: args,
    });

    // Execute the tool
    let result: TronToolResult;
    try {
      result = await this.invokeToolFunction(tool, request.toolCallId, args);
    } catch (error) {
      const structuredError = categorizeError(error, {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
      });
      logger.error('Tool execution failed', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
        error: structuredError.message,
        code: structuredError.code,
        category: structuredError.category,
        recoverable: structuredError.recoverable,
      });
      result = {
        content: `Tool execution error: ${error instanceof Error ? error.message : String(error)}`,
        isError: true,
      };
    }

    const duration = Date.now() - startTime;

    // Process result through context manager safety net
    const contentString = this.resultToString(result);
    const processed = this.contextManager.processToolResult({
      toolCallId: request.toolCallId,
      content: contentString,
    });

    let finalContent = contentString;
    if (processed.truncated) {
      finalContent = processed.content;
      logger.info('Tool result truncated by context manager safety net', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        originalSize: processed.originalSize,
        finalSize: finalContent.length,
      });
    }

    // Emit tool execution end event
    this.eventEmitter.emit({
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
    await this.executePostHooks(request, result, duration);

    this.activeTool = null;

    // Log successful completion
    if (!result.isError) {
      logger.info('Tool execution completed', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
        duration,
        resultSize: finalContent.length,
      });
    }

    return {
      toolCallId: request.toolCallId,
      result: {
        content: finalContent,
        isError: result.isError ?? false,
        details: result.details as Record<string, unknown> | undefined,
        stopTurn: result.stopTurn,
      },
      duration,
    };
  }

  /**
   * Execute pre-tool hooks
   */
  private async executePreHooks(
    request: ToolExecutionRequest
  ): Promise<{ blocked: boolean; reason?: string; modifiedArgs?: Record<string, unknown> }> {
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
    const preHookStartTime = Date.now();
    if (preHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: preHooks.map(h => h.name),
        hookEvent: 'PreToolUse',
        toolName: request.toolName,
        toolCallId: request.toolCallId,
      });
    }

    const preResult = await this.hookEngine.execute('PreToolUse', preContext);

    if (preHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: preHooks.map(h => h.name),
        hookEvent: 'PreToolUse',
        result: preResult.action,
        duration: Date.now() - preHookStartTime,
        reason: preResult.reason,
        toolName: request.toolName,
        toolCallId: request.toolCallId,
      });
    }

    if (preResult.action === 'block') {
      logger.info('Tool blocked by PreToolUse hook', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
        reason: preResult.reason,
        hooks: preHooks.map(h => h.name),
      });
      return { blocked: true, reason: preResult.reason };
    }

    if (preResult.action === 'modify' && preResult.modifications) {
      logger.debug('Tool arguments modified by PreToolUse hook', {
        toolName: request.toolName,
        toolCallId: request.toolCallId,
        sessionId: this.sessionId,
        modifiedKeys: Object.keys(preResult.modifications),
      });
      return {
        blocked: false,
        modifiedArgs: { ...request.arguments, ...preResult.modifications },
      };
    }

    return { blocked: false };
  }

  /**
   * Execute post-tool hooks
   */
  private async executePostHooks(
    request: ToolExecutionRequest,
    result: TronToolResult,
    duration: number
  ): Promise<void> {
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
    const postHookStartTime = Date.now();
    if (postHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: postHooks.map(h => h.name),
        hookEvent: 'PostToolUse',
        toolName: request.toolName,
        toolCallId: request.toolCallId,
      });
    }

    const postResult = await this.hookEngine.execute('PostToolUse', postContext);

    if (postHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: postHooks.map(h => h.name),
        hookEvent: 'PostToolUse',
        result: postResult.action,
        duration: Date.now() - postHookStartTime,
        reason: postResult.reason,
        toolName: request.toolName,
        toolCallId: request.toolCallId,
      });
    }
  }

  /**
   * Invoke the tool function with the appropriate signature
   */
  private async invokeToolFunction(
    tool: TronTool,
    toolCallId: string,
    args: Record<string, unknown>
  ): Promise<TronToolResult> {
    // Handle both old (params) and new (toolCallId, params, signal) signatures
    if (tool.execute.length >= 3) {
      // New signature: (toolCallId, params, signal, onProgress)
      const signal = this.getAbortSignal() ?? new AbortController().signal;
      return (tool.execute as (
        id: string,
        p: Record<string, unknown>,
        s: AbortSignal
      ) => Promise<TronToolResult>)(toolCallId, args, signal);
    } else {
      // Old signature: (params)
      return (tool.execute as (p: Record<string, unknown>) => Promise<TronToolResult>)(args);
    }
  }

  /**
   * Convert tool result content to string
   */
  private resultToString(result: TronToolResult): string {
    if (typeof result.content === 'string') {
      return result.content;
    }
    return result.content.map(c => (c.type === 'text' ? c.text : '[image]')).join('\n');
  }
}

/**
 * Create a tool executor instance
 */
export function createToolExecutor(deps: ToolExecutorDependencies): AgentToolExecutor {
  return new AgentToolExecutor(deps);
}
