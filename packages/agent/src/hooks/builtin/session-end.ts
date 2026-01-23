/**
 * @fileoverview SessionEnd Built-in Hook
 *
 * Executes when a session ends.
 * Session history is preserved via the event-sourced system (~/.tron/db/).
 */

import type {
  HookDefinition,
  SessionEndHookContext,
  HookResult,
} from '../types.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('hooks:session-end');

/**
 * Configuration for SessionEnd hook
 */
export interface SessionEndHookConfig {
  /** Minimum message count to process (default: 2) */
  minMessagesForProcessing?: number;
}

/**
 * Extended context for session end processing
 */
export interface SessionEndContext extends SessionEndHookContext {
  /** Messages from the session */
  messages?: Array<{
    role: string;
    content: string;
  }>;
  /** Tool calls made during session */
  toolCalls?: Array<{
    name: string;
    arguments: Record<string, unknown>;
    result?: string;
  }>;
  /** Files modified during session */
  filesModified?: Array<{
    path: string;
    operation: 'create' | 'modify' | 'delete';
  }>;
  /** Session outcome */
  outcome?: 'completed' | 'aborted' | 'error';
  /** Error if session failed */
  error?: string;
}

/**
 * Create the SessionEnd hook
 *
 * This hook runs when a session ends.
 * Session history is automatically preserved via the event-sourced system.
 */
export function createSessionEndHook(
  config: SessionEndHookConfig = {}
): HookDefinition {
  const { minMessagesForProcessing = 2 } = config;

  return {
    name: 'builtin:session-end',
    type: 'SessionEnd',
    description: 'Logs session completion',
    priority: 100,

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as SessionEndContext;
      logger.info('SessionEnd hook executing', {
        sessionId: context.sessionId,
        messageCount: context.messageCount,
        toolCallCount: context.toolCallCount,
        outcome: context.outcome,
      });

      // Skip processing for very short sessions
      if (context.messageCount < minMessagesForProcessing) {
        logger.debug('Session too short for processing', {
          messageCount: context.messageCount,
          minimum: minMessagesForProcessing,
        });
        return { action: 'continue' };
      }

      // Generate summary for logging
      const summary = generateSummary(context);

      return {
        action: 'continue',
        message: summary,
        modifications: {
          sessionEnded: true,
          outcome: context.outcome ?? 'completed',
        },
      };
    },
  };
}

/**
 * Generate summary from session context
 */
function generateSummary(context: SessionEndContext): string {
  const parts: string[] = [];

  if (context.toolCallCount > 0) {
    parts.push(`Made ${context.toolCallCount} tool calls`);
  }

  if (context.outcome === 'error' && context.error) {
    parts.push(`Ended with error: ${context.error}`);
  }

  return parts.join('. ') || 'Session completed';
}

export default createSessionEndHook;
