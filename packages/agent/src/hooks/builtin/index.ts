/**
 * @fileoverview Built-in Hooks Module
 *
 * Exports all built-in hooks for the agent lifecycle.
 *
 * Built-in hooks provide:
 * - SessionStart: Initialize session context
 * - SessionEnd: Log session completion
 * - PreCompact: Checkpoint before context compaction
 * - PostToolUse: Track file modifications
 *
 * Note: Session history is preserved via the event-sourced system.
 */

import type { HookEngine } from '../engine.js';
import { createLogger } from '../../logging/index.js';

// Export individual hook creators
export {
  createSessionStartHook,
  type SessionStartHookConfig,
} from './session-start.js';

export {
  createSessionEndHook,
  type SessionEndHookConfig,
  type SessionEndContext,
} from './session-end.js';

export {
  createPreCompactHook,
  type PreCompactHookConfig,
  type PreCompactContext,
} from './pre-compact.js';

export {
  createPostToolUseHook,
  type PostToolUseHookConfig,
} from './post-tool-use.js';

const logger = createLogger('hooks:builtin');

/**
 * Configuration for registering all built-in hooks
 */
export interface BuiltinHooksConfig {
  /** Options for individual hooks */
  options?: {
    sessionStart?: {
      initialContext?: string;
    };
    sessionEnd?: {
      minMessagesForProcessing?: number;
    };
    preCompact?: {
      checkpointThreshold?: number;
    };
    postToolUse?: {
      trackFiles?: boolean;
      maxTrackedFiles?: number;
    };
  };
}

/**
 * Register all built-in hooks with the engine
 *
 * This is a convenience function that sets up all built-in hooks
 * with the provided configuration.
 */
export function registerBuiltinHooks(
  engine: HookEngine,
  config: BuiltinHooksConfig = {}
): void {
  const { options = {} } = config;

  // Import hook creators dynamically to avoid circular dependencies
  const { createSessionStartHook } = require('./session-start.js');
  const { createSessionEndHook } = require('./session-end.js');
  const { createPreCompactHook } = require('./pre-compact.js');
  const { createPostToolUseHook } = require('./post-tool-use.js');

  // Register SessionStart hook
  engine.register(
    createSessionStartHook({
      ...options.sessionStart,
    })
  );

  // Register SessionEnd hook
  engine.register(
    createSessionEndHook({
      ...options.sessionEnd,
    })
  );

  // Register PreCompact hook
  engine.register(
    createPreCompactHook({
      ...options.preCompact,
    })
  );

  // Register PostToolUse hook
  engine.register(
    createPostToolUseHook({
      ...options.postToolUse,
    })
  );

  logger.info('Built-in hooks registered', {
    hooks: ['session-start', 'session-end', 'pre-compact', 'post-tool-use'],
  });
}
