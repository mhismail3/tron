/**
 * @fileoverview Hook Context Factory
 *
 * Provides factory functions for creating hook contexts with
 * consistent base fields (sessionId, timestamp, data).
 * Eliminates repeated context construction boilerplate.
 */

import type { TronToolResult } from '@core/types/index.js';
import type {
  PreToolHookContext,
  PostToolHookContext,
  StopHookContext,
  SessionStartHookContext,
  SessionEndHookContext,
  UserPromptSubmitHookContext,
  SubagentStopHookContext,
} from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Options for creating a hook context factory
 */
export interface HookContextFactoryOptions {
  /** Session ID for all contexts created by this factory */
  sessionId: string;
}

/**
 * Options for creating a PreToolUse context
 */
export interface PreToolContextOptions {
  toolName: string;
  toolArguments: Record<string, unknown>;
  toolCallId: string;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a PostToolUse context
 */
export interface PostToolContextOptions {
  toolName: string;
  toolCallId: string;
  result: TronToolResult;
  duration: number;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a Stop context
 */
export interface StopContextOptions {
  stopReason: string;
  finalMessage?: string;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a SessionStart context
 */
export interface SessionStartContextOptions {
  workingDirectory: string;
  parentHandoffId?: string;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a SessionEnd context
 */
export interface SessionEndContextOptions {
  messageCount: number;
  toolCallCount: number;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a UserPromptSubmit context
 */
export interface UserPromptSubmitContextOptions {
  prompt: string;
  data?: Record<string, unknown>;
}

/**
 * Options for creating a SubagentStop context
 */
export interface SubagentStopContextOptions {
  subagentId: string;
  stopReason: string;
  result?: unknown;
  data?: Record<string, unknown>;
}

/**
 * Hook context factory interface
 */
export interface HookContextFactory {
  createPreToolContext(options: PreToolContextOptions): PreToolHookContext;
  createPostToolContext(options: PostToolContextOptions): PostToolHookContext;
  createStopContext(options: StopContextOptions): StopHookContext;
  createSessionStartContext(options: SessionStartContextOptions): SessionStartHookContext;
  createSessionEndContext(options: SessionEndContextOptions): SessionEndHookContext;
  createUserPromptSubmitContext(options: UserPromptSubmitContextOptions): UserPromptSubmitHookContext;
  createSubagentStopContext(options: SubagentStopContextOptions): SubagentStopHookContext;
}

// =============================================================================
// Implementation
// =============================================================================

/**
 * Create a hook context factory for a specific session
 *
 * @example
 * ```typescript
 * const factory = createHookContextFactory({
 *   sessionId: 'sess_123',
 * });
 *
 * const preContext = factory.createPreToolContext({
 *   toolName: 'Bash',
 *   toolArguments: { command: 'ls' },
 *   toolCallId: 'tool_abc',
 * });
 * ```
 */
export function createHookContextFactory(options: HookContextFactoryOptions): HookContextFactory {
  const { sessionId } = options;

  const createTimestamp = (): string => new Date().toISOString();

  return {
    createPreToolContext(opts: PreToolContextOptions): PreToolHookContext {
      return {
        hookType: 'PreToolUse',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        toolName: opts.toolName,
        toolArguments: opts.toolArguments,
        toolCallId: opts.toolCallId,
      };
    },

    createPostToolContext(opts: PostToolContextOptions): PostToolHookContext {
      return {
        hookType: 'PostToolUse',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        toolName: opts.toolName,
        toolCallId: opts.toolCallId,
        result: opts.result,
        duration: opts.duration,
      };
    },

    createStopContext(opts: StopContextOptions): StopHookContext {
      return {
        hookType: 'Stop',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        stopReason: opts.stopReason,
        finalMessage: opts.finalMessage,
      };
    },

    createSessionStartContext(opts: SessionStartContextOptions): SessionStartHookContext {
      return {
        hookType: 'SessionStart',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        workingDirectory: opts.workingDirectory,
        parentHandoffId: opts.parentHandoffId,
      };
    },

    createSessionEndContext(opts: SessionEndContextOptions): SessionEndHookContext {
      return {
        hookType: 'SessionEnd',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        messageCount: opts.messageCount,
        toolCallCount: opts.toolCallCount,
      };
    },

    createUserPromptSubmitContext(opts: UserPromptSubmitContextOptions): UserPromptSubmitHookContext {
      return {
        hookType: 'UserPromptSubmit',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        prompt: opts.prompt,
      };
    },

    createSubagentStopContext(opts: SubagentStopContextOptions): SubagentStopHookContext {
      return {
        hookType: 'SubagentStop',
        sessionId,
        timestamp: createTimestamp(),
        data: opts.data ?? {},
        subagentId: opts.subagentId,
        stopReason: opts.stopReason,
        result: opts.result,
      };
    },
  };
}
