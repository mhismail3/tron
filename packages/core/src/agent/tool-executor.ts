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
import { createLogger } from '../logging/logger.js';

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

  private activeTool: string | null = null;

  constructor(deps: ToolExecutorDependencies) {
    this.tools = deps.tools;
    this.hookEngine = deps.hookEngine;
    this.contextManager = deps.contextManager;
    this.eventEmitter = deps.eventEmitter;
    this.sessionId = deps.sessionId;
    this.getAbortSignal = deps.getAbortSignal;
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

    if (!tool) {
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
    if (preHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: preHooks.map(h => h.name).join(', '),
        hookEvent: 'PreToolUse',
      });
    }

    const preResult = await this.hookEngine.execute('PreToolUse', preContext);

    if (preHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: preHooks.map(h => h.name).join(', '),
        hookEvent: 'PreToolUse',
        result: preResult.action,
      });
    }

    if (preResult.action === 'block') {
      return { blocked: true, reason: preResult.reason };
    }

    if (preResult.action === 'modify' && preResult.modifications) {
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
    if (postHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_triggered',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: postHooks.map(h => h.name).join(', '),
        hookEvent: 'PostToolUse',
      });
    }

    const postResult = await this.hookEngine.execute('PostToolUse', postContext);

    if (postHooks.length > 0) {
      this.eventEmitter.emit({
        type: 'hook_completed',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        hookName: postHooks.map(h => h.name).join(', '),
        hookEvent: 'PostToolUse',
        result: postResult.action,
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
