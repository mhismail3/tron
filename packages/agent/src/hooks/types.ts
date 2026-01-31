/**
 * @fileoverview Hook type definitions
 *
 * Hooks provide lifecycle interception points for the agent.
 */

import type { TronToolResult } from '../types/index.js';

// =============================================================================
// Hook Types
// =============================================================================

/**
 * Available hook types
 */
export type HookType =
  | 'PreToolUse'      // Before tool execution
  | 'PostToolUse'     // After tool execution
  | 'Stop'            // When agent stops
  | 'SubagentStop'    // When subagent stops
  | 'SessionStart'    // Session begins
  | 'SessionEnd'      // Session ends
  | 'UserPromptSubmit' // User submits prompt
  | 'PreCompact'      // Before context compaction
  | 'Notification';   // Notification events

/**
 * Notification severity levels
 */
export type NotificationLevel = 'debug' | 'info' | 'warning' | 'error';

// =============================================================================
// Hook Results
// =============================================================================

/**
 * Result actions that hooks can return
 */
export type HookAction = 'continue' | 'block' | 'modify';

/**
 * Result of hook execution
 */
export interface HookResult {
  action: HookAction;
  reason?: string;
  message?: string;
  modifications?: Record<string, unknown>;
}

// =============================================================================
// Hook Contexts
// =============================================================================

/**
 * Base hook context
 */
export interface HookContext {
  hookType: HookType;
  sessionId: string;
  timestamp: string;
  data: Record<string, unknown>;
}

/**
 * PreToolUse hook context
 */
export interface PreToolHookContext extends HookContext {
  hookType: 'PreToolUse';
  toolName: string;
  toolArguments: Record<string, unknown>;
  toolCallId: string;
}

/**
 * PostToolUse hook context
 */
export interface PostToolHookContext extends HookContext {
  hookType: 'PostToolUse';
  toolName: string;
  toolCallId: string;
  result: TronToolResult;
  duration: number;
}

/**
 * Stop hook context
 */
export interface StopHookContext extends HookContext {
  hookType: 'Stop';
  stopReason: string;
  finalMessage?: string;
}

/**
 * SubagentStop hook context
 */
export interface SubagentStopHookContext extends HookContext {
  hookType: 'SubagentStop';
  subagentId: string;
  stopReason: string;
  result?: unknown;
}

/**
 * SessionStart hook context
 */
export interface SessionStartHookContext extends HookContext {
  hookType: 'SessionStart';
  workingDirectory: string;
  parentHandoffId?: string;
}

/**
 * SessionEnd hook context
 */
export interface SessionEndHookContext extends HookContext {
  hookType: 'SessionEnd';
  messageCount: number;
  toolCallCount: number;
}

/**
 * UserPromptSubmit hook context
 */
export interface UserPromptSubmitHookContext extends HookContext {
  hookType: 'UserPromptSubmit';
  prompt: string;
}

/**
 * PreCompact hook context
 */
export interface PreCompactHookContext extends HookContext {
  hookType: 'PreCompact';
  currentTokens: number;
  targetTokens: number;
}

/**
 * Notification hook context
 */
export interface NotificationHookContext extends HookContext {
  hookType: 'Notification';
  level: NotificationLevel;
  title: string;
  body?: string;
}

/**
 * Union of all hook contexts
 */
export type AnyHookContext =
  | PreToolHookContext
  | PostToolHookContext
  | StopHookContext
  | SubagentStopHookContext
  | SessionStartHookContext
  | SessionEndHookContext
  | UserPromptSubmitHookContext
  | PreCompactHookContext
  | NotificationHookContext;

// =============================================================================
// Hook Definition
// =============================================================================

/**
 * Hook handler function
 */
export type HookHandler = (context: AnyHookContext) => Promise<HookResult>;

/**
 * Filter function for selective hook execution
 */
export type HookFilter = (context: AnyHookContext) => boolean;

/**
 * Hook execution mode
 * - 'blocking': Agent waits for hook to complete (default)
 * - 'background': Fire-and-forget, agent continues immediately
 */
export type HookExecutionMode = 'blocking' | 'background';

/**
 * Hook definition for registration
 */
export interface HookDefinition {
  name: string;
  type: HookType;
  description?: string;
  priority?: number;  // Higher runs first (default: 0)
  timeout?: number;   // Max execution time in ms
  mode?: HookExecutionMode;  // Default: 'blocking'
  filter?: HookFilter;
  handler: HookHandler;
}

/**
 * Registered hook with internal state
 */
export interface RegisteredHook extends HookDefinition {
  registeredAt: string;
  mode: HookExecutionMode;  // Always defined after registration
}

/**
 * Hook interface for execution
 */
export interface Hook {
  name: string;
  type: HookType;
  execute(context: AnyHookContext): Promise<HookResult>;
}
