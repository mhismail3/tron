/**
 * @fileoverview Tron tool types
 *
 * These types define the structure of tools in the Tron agent system.
 * Tools are functions that the agent can call to interact with the environment.
 */

import type { TextContent, ImageContent } from './messages.js';

// =============================================================================
// Tool Schema Types
// =============================================================================

/**
 * JSON Schema-like parameter definition
 */
export interface ToolParameterSchema {
  type: 'object' | 'string' | 'number' | 'boolean' | 'array';
  properties?: Record<string, ToolParameterProperty>;
  required?: string[];
  items?: ToolParameterProperty;
  description?: string;
}

/**
 * Individual parameter property
 */
export interface ToolParameterProperty {
  type: 'string' | 'number' | 'boolean' | 'array' | 'object';
  description?: string;
  enum?: string[];
  default?: unknown;
  items?: ToolParameterProperty;
  properties?: Record<string, ToolParameterProperty>;
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
 */
export interface TronToolResult<TDetails = unknown> {
  content: ToolResultContentType[];
  details?: TDetails;
  isError?: boolean;
}

/**
 * Progress update callback for long-running tools
 */
export type ToolProgressCallback = (update: string) => void;

/**
 * Tool execution function signature
 */
export type ToolExecuteFunction<TParams = unknown, TDetails = unknown> = (
  toolCallId: string,
  params: TParams,
  signal: AbortSignal,
  onProgress?: ToolProgressCallback
) => Promise<TronToolResult<TDetails>>;

/**
 * Full Tron tool definition with execution
 */
export interface TronTool<TParams = unknown, TDetails = unknown> extends Tool {
  /**
   * Human-readable label for UI display
   */
  label: string;

  /**
   * Execute the tool with the given parameters
   */
  execute: ToolExecuteFunction<TParams, TDetails>;

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
