/**
 * @fileoverview Built-in Hooks Module
 *
 * Exports all built-in hooks for the agent lifecycle.
 * These hooks integrate the memory layer with the agent loop.
 *
 * Built-in hooks provide:
 * - SessionStart: Load ledger and handoff context
 * - SessionEnd: Create handoffs and extract learnings
 * - PreCompact: Auto-checkpoint before context compaction
 * - PostToolUse: Track file modifications
 *
 * @example
 * ```typescript
 * import {
 *   createSessionStartHook,
 *   createSessionEndHook,
 *   createPreCompactHook,
 *   createPostToolUseHook,
 *   registerBuiltinHooks,
 * } from '@tron/core/hooks/builtin';
 *
 * // Register all built-in hooks
 * registerBuiltinHooks(engine, {
 *   ledgerManager,
 *   handoffManager,
 * });
 * ```
 */

import type { HookEngine } from '../engine.js';
import type { LedgerManager } from '../../memory/ledger-manager.js';
import type { HandoffManager } from '../../memory/handoff-manager.js';
import { createLogger } from '../../logging/logger.js';

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
  /** Ledger manager for session state */
  ledgerManager: LedgerManager;
  /** Handoff manager for persistence */
  handoffManager: HandoffManager;
  /** Options for individual hooks */
  options?: {
    sessionStart?: {
      handoffLimit?: number;
      includeWorkingFiles?: boolean;
    };
    sessionEnd?: {
      minMessagesForHandoff?: number;
      clearLedgerOnEnd?: boolean;
    };
    preCompact?: {
      blockUntilHandoff?: boolean;
      autoHandoffThreshold?: number;
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
  config: BuiltinHooksConfig
): void {
  const { ledgerManager, handoffManager, options = {} } = config;

  // Import hook creators dynamically to avoid circular dependencies
  const { createSessionStartHook } = require('./session-start.js');
  const { createSessionEndHook } = require('./session-end.js');
  const { createPreCompactHook } = require('./pre-compact.js');
  const { createPostToolUseHook } = require('./post-tool-use.js');

  // Register SessionStart hook
  engine.register(
    createSessionStartHook({
      ledgerManager,
      handoffManager,
      ...options.sessionStart,
    })
  );

  // Register SessionEnd hook
  engine.register(
    createSessionEndHook({
      handoffManager,
      ledgerManager,
      ...options.sessionEnd,
    })
  );

  // Register PreCompact hook
  engine.register(
    createPreCompactHook({
      handoffManager,
      ledgerManager,
      ...options.preCompact,
    })
  );

  // Register PostToolUse hook
  engine.register(
    createPostToolUseHook({
      ledgerManager,
      ...options.postToolUse,
    })
  );

  logger.info('Built-in hooks registered', {
    hooks: ['session-start', 'session-end', 'pre-compact', 'post-tool-use'],
  });
}
