/**
 * @fileoverview PreCompact Built-in Hook
 *
 * Executes before context compaction.
 * Session history is preserved via the event-sourced system (~/.tron/db/).
 */

import type {
  HookDefinition,
  PreCompactHookContext,
  HookResult,
} from '../types.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('hooks:pre-compact');

/**
 * Configuration for PreCompact hook
 */
export interface PreCompactHookConfig {
  /** Token threshold to trigger checkpoint logging (default: 80% of target) */
  checkpointThreshold?: number;
}

/**
 * Extended context for pre-compact processing
 */
export interface PreCompactContext extends PreCompactHookContext {
  /** Session messages to be compacted */
  messages?: Array<{
    role: string;
    content: string;
    timestamp?: string;
  }>;
  /** Tool calls in current context */
  toolCalls?: Array<{
    name: string;
    timestamp?: string;
  }>;
  /** Compaction reason */
  reason?: 'token_limit' | 'manual' | 'auto';
}

/**
 * Create the PreCompact hook
 *
 * This hook runs before context compaction and logs the checkpoint.
 * Full session history is preserved via the event store.
 */
export function createPreCompactHook(
  config: PreCompactHookConfig = {}
): HookDefinition {
  const { checkpointThreshold = 0.8 } = config;

  return {
    name: 'builtin:pre-compact',
    type: 'PreCompact',
    description: 'Logs checkpoint before context compaction',
    priority: 100,

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as PreCompactContext;
      logger.info('PreCompact hook executing', {
        sessionId: context.sessionId,
        currentTokens: context.currentTokens,
        targetTokens: context.targetTokens,
        reason: context.reason,
      });

      const tokenRatio = context.currentTokens / context.targetTokens;

      // Check if we should log checkpoint
      if (tokenRatio < checkpointThreshold) {
        logger.debug('Below checkpoint threshold, skipping', {
          ratio: tokenRatio,
          threshold: checkpointThreshold,
        });
        return { action: 'continue' };
      }

      // Generate continuation context
      const continuationContext = generateContinuationContext(
        context.currentTokens
      );

      return {
        action: 'continue',
        message: continuationContext,
        modifications: {
          checkpointCreated: true,
          continuationContext,
        },
      };
    },
  };
}

/**
 * Generate context for continuation after compaction
 */
function generateContinuationContext(tokensAtCompaction: number): string {
  const parts: string[] = [];

  parts.push('## Session Continuation (Post-Compaction)\n');
  parts.push(`*Checkpoint at ${tokensAtCompaction} tokens*\n`);
  parts.push('Session history is preserved in the event store.');

  return parts.join('\n');
}

export default createPreCompactHook;
