/**
 * @fileoverview Context factory helpers for hook testing
 *
 * Type-safe factories for creating hook contexts in tests.
 * Each factory creates a properly typed context with sensible defaults.
 */

import type {
  SessionStartHookContext,
  SessionEndHookContext,
  UserPromptSubmitHookContext,
  StopHookContext,
  SubagentStopHookContext,
  PreToolHookContext,
  PostToolHookContext,
  PreCompactHookContext,
  NotificationHookContext,
  NotificationLevel,
} from '../types.js';
import type { TronToolResult } from '../../types/index.js';

/**
 * Create a SessionStart hook context
 */
export function createSessionStartContext(opts: {
  sessionId: string;
  workingDirectory?: string;
  parentHandoffId?: string;
  timestamp?: string;
  data?: Record<string, unknown>;
}): SessionStartHookContext {
  return {
    hookType: 'SessionStart',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    workingDirectory: opts.workingDirectory ?? '/test',
    parentHandoffId: opts.parentHandoffId,
  };
}

/**
 * Create a SessionEnd hook context
 */
export function createSessionEndContext(opts: {
  sessionId: string;
  messageCount?: number;
  toolCallCount?: number;
  timestamp?: string;
  data?: Record<string, unknown>;
}): SessionEndHookContext {
  return {
    hookType: 'SessionEnd',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    messageCount: opts.messageCount ?? 0,
    toolCallCount: opts.toolCallCount ?? 0,
  };
}

/**
 * Create a UserPromptSubmit hook context
 */
export function createUserPromptSubmitContext(opts: {
  sessionId: string;
  prompt: string;
  timestamp?: string;
  data?: Record<string, unknown>;
}): UserPromptSubmitHookContext {
  return {
    hookType: 'UserPromptSubmit',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    prompt: opts.prompt,
  };
}

/**
 * Create a Stop hook context
 */
export function createStopContext(opts: {
  sessionId: string;
  stopReason: string;
  finalMessage?: string;
  timestamp?: string;
  data?: Record<string, unknown>;
}): StopHookContext {
  return {
    hookType: 'Stop',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    stopReason: opts.stopReason,
    finalMessage: opts.finalMessage,
  };
}

/**
 * Create a SubagentStop hook context
 */
export function createSubagentStopContext(opts: {
  sessionId: string;
  subagentId: string;
  stopReason: string;
  result?: unknown;
  timestamp?: string;
  data?: Record<string, unknown>;
}): SubagentStopHookContext {
  return {
    hookType: 'SubagentStop',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    subagentId: opts.subagentId,
    stopReason: opts.stopReason,
    result: opts.result,
  };
}

/**
 * Create a PreToolUse hook context
 */
export function createPreToolUseContext(opts: {
  sessionId: string;
  toolName: string;
  toolCallId: string;
  toolArguments?: Record<string, unknown>;
  timestamp?: string;
  data?: Record<string, unknown>;
}): PreToolHookContext {
  return {
    hookType: 'PreToolUse',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    toolName: opts.toolName,
    toolCallId: opts.toolCallId,
    toolArguments: opts.toolArguments ?? {},
  };
}

/**
 * Create a PostToolUse hook context
 */
export function createPostToolUseContext(opts: {
  sessionId: string;
  toolName: string;
  toolCallId: string;
  result: TronToolResult;
  duration: number;
  timestamp?: string;
  data?: Record<string, unknown>;
}): PostToolHookContext {
  return {
    hookType: 'PostToolUse',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    toolName: opts.toolName,
    toolCallId: opts.toolCallId,
    result: opts.result,
    duration: opts.duration,
  };
}

/**
 * Create a PreCompact hook context
 */
export function createPreCompactContext(opts: {
  sessionId: string;
  currentTokens: number;
  targetTokens: number;
  timestamp?: string;
  data?: Record<string, unknown>;
}): PreCompactHookContext {
  return {
    hookType: 'PreCompact',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    currentTokens: opts.currentTokens,
    targetTokens: opts.targetTokens,
  };
}

/**
 * Create a Notification hook context
 */
export function createNotificationContext(opts: {
  sessionId: string;
  level: NotificationLevel;
  title: string;
  body?: string;
  timestamp?: string;
  data?: Record<string, unknown>;
}): NotificationHookContext {
  return {
    hookType: 'Notification',
    sessionId: opts.sessionId,
    timestamp: opts.timestamp ?? new Date().toISOString(),
    data: opts.data ?? {},
    level: opts.level,
    title: opts.title,
    body: opts.body,
  };
}
