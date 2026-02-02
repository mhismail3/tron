/**
 * @fileoverview SessionStart Built-in Hook
 *
 * Executes when a new session begins.
 * Session history is available via the event-sourced system (~/.tron/db/).
 */

import type {
  HookDefinition,
  SessionStartHookContext,
  HookResult,
} from '../types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('hooks:session-start');

/**
 * Configuration for SessionStart hook
 */
export interface SessionStartHookConfig {
  /** Custom context to inject at session start */
  initialContext?: string;
}

/**
 * SessionStart hook result
 */
export interface SessionStartResult extends HookResult {
  /** Context injected into the session */
  context?: Record<string, unknown>;
}

/**
 * Create the SessionStart hook
 *
 * This hook runs at the beginning of each session.
 * Session history is available via the event store tree structure.
 */
export function createSessionStartHook(
  config: SessionStartHookConfig = {}
): HookDefinition {
  const { initialContext } = config;

  return {
    name: 'builtin:session-start',
    type: 'SessionStart',
    description: 'Initializes session context',
    priority: 100,

    handler: async (ctx): Promise<SessionStartResult> => {
      const context = ctx as SessionStartHookContext;
      logger.info('SessionStart hook executing', {
        sessionId: context.sessionId,
        workingDirectory: context.workingDirectory,
      });

      return {
        action: initialContext ? 'modify' : 'continue',
        message: initialContext,
        modifications: initialContext ? { systemContext: initialContext } : undefined,
      };
    },
  };
}

export default createSessionStartHook;
