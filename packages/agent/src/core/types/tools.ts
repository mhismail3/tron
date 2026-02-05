/**
 * @fileoverview Tron tool types
 *
 * These types define the structure of tools in the Tron agent system.
 * Tools are functions that the agent can call to interact with the environment.
 */

import type { TextContent, ImageContent } from './content.js';

// =============================================================================
// Tool Schema Types
// =============================================================================

/**
 * Individual parameter property - JSON Schema compatible
 */
export interface ToolParameterProperty {
  type: 'string' | 'number' | 'boolean' | 'array' | 'object';
  description?: string;
  enum?: string[];
  default?: unknown;
  items?: ToolParameterProperty;
  properties?: Record<string, ToolParameterProperty>;
  /** Allow additional JSON Schema properties */
  [key: string]: unknown;
}

/**
 * JSON Schema-like parameter definition
 */
export interface ToolParameterSchema {
  type: 'object' | 'string' | 'number' | 'boolean' | 'array';
  properties?: Record<string, ToolParameterProperty>;
  required?: string[];
  items?: ToolParameterProperty;
  description?: string;
  /** Allow additional JSON Schema properties */
  [key: string]: unknown;
}

// =============================================================================
// Base Tool Definition
// =============================================================================

/**
 * Basic tool definition (for LLM context)
 */
export interface Tool {
  name: string;
  description: string;
  parameters: ToolParameterSchema;
}

// =============================================================================
// Tron Tool Types
// =============================================================================

/**
 * Content types that can appear in tool results
 */
export type ToolResultContentType = TextContent | ImageContent;

/**
 * Result from tool execution
 * Content can be either a string (for simple text) or structured content
 */
export interface TronToolResult<TDetails = unknown> {
  content: string | ToolResultContentType[];
  details?: TDetails;
  isError?: boolean;
  /**
   * If true, stops the agent turn loop immediately after this tool executes.
   * Used by async tools like AskUserQuestion that need user input before continuing.
   * The tool result is still added to context, but no further API call is made this turn.
   */
  stopTurn?: boolean;
}

/**
 * Progress update callback for long-running tools
 */
export type ToolProgressCallback = (update: string) => void;

/**
 * Explicit execution contract for tool invocation.
 */
export type ToolExecutionContract = 'legacy' | 'contextual' | 'options';

/**
 * Structured execution options for tools that use the options contract.
 */
export interface ToolExecutionOptions {
  toolCallId?: string;
  sessionId?: string;
  signal?: AbortSignal;
  onProgress?: ToolProgressCallback;
}

/**
 * Tool execution function signatures.
 *
 * `legacy`:
 * - execute(params)
 *
 * `contextual`:
 * - execute(toolCallId, params, signal)
 *
 * `options`:
 * - execute(params, { toolCallId, sessionId, signal, onProgress? })
 */
export type ToolExecuteFunction<
  TParams = never,
  TDetails = unknown,
> =
  | ((params: TParams) => Promise<TronToolResult<TDetails>>)
  | ((
      toolCallId: string,
      params: TParams,
      signal: AbortSignal
    ) => Promise<TronToolResult<TDetails>>)
  | ((
      params: TParams,
      options?: ToolExecutionOptions
    ) => Promise<TronToolResult<TDetails>>);

type BivariantToolExecuteFunction<TParams, TDetails> = {
  bivarianceHack: ToolExecuteFunction<TParams, TDetails>;
}['bivarianceHack'];

/**
 * Full Tron tool definition with execution
 */
export interface TronTool<
  TParams = never,
  TDetails = unknown,
> extends Tool {
  /**
   * Human-readable label for UI display
   */
  label?: string;

  /**
   * Execute the tool with the given parameters
   * Supports both (params) and (toolCallId, params, signal, onProgress) signatures
   */
  execute: BivariantToolExecuteFunction<TParams, TDetails>;

  /**
   * Explicit invocation contract used by AgentToolExecutor.
   * If omitted, executor defaults to the `legacy` contract.
   */
  executionContract?: ToolExecutionContract;

  /**
   * Optional timeout in milliseconds
   */
  timeout?: number;

  /**
   * Whether this tool requires user confirmation before execution
   */
  requiresConfirmation?: boolean;

  /**
   * Tool category for grouping
   */
  category?: 'filesystem' | 'shell' | 'search' | 'network' | 'custom';
}

// =============================================================================
// Type Guards
// =============================================================================

export function isTronTool(tool: Tool): tool is TronTool {
  return 'execute' in tool && typeof (tool as TronTool).execute === 'function';
}

// =============================================================================
// Tool Factory Helpers
// =============================================================================

/**
 * Create a simple text result
 */
export function textResult(text: string, isError = false): TronToolResult {
  return {
    content: [{ type: 'text', text }],
    isError,
  };
}

/**
 * Create an error result
 */
export function errorResult(message: string): TronToolResult {
  return textResult(message, true);
}

/**
 * Create an image result
 */
export function imageResult(
  data: string,
  mimeType: string,
  caption?: string
): TronToolResult {
  const content: ToolResultContentType[] = [];
  if (caption) {
    content.push({ type: 'text', text: caption });
  }
  content.push({ type: 'image', data, mimeType });
  return { content };
}
