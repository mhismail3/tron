/**
 * @fileoverview SessionStart Built-in Hook
 *
 * Executes when a new session begins. Responsibilities:
 * - Load the continuity ledger from disk
 * - Retrieve recent handoffs for context
 * - Inject session context into the agent prompt
 * - Set up working file tracking
 *
 * This hook is critical for session continuity across agent restarts.
 *
 * @example
 * ```typescript
 * import { createSessionStartHook } from './session-start';
 *
 * const hook = createSessionStartHook({
 *   ledgerManager,
 *   handoffManager,
 * });
 *
 * engine.register(hook);
 * ```
 */

import type {
  HookDefinition,
  SessionStartHookContext,
  HookResult,
} from '../types.js';
import type { LedgerManager } from '../../memory/ledger-manager.js';
import type { HandoffManager } from '../../memory/handoff-manager.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('hooks:session-start');

/**
 * Configuration for SessionStart hook
 */
export interface SessionStartHookConfig {
  /** Ledger manager for session state */
  ledgerManager: LedgerManager;
  /** Handoff manager for context retrieval */
  handoffManager?: HandoffManager;
  /** Number of recent handoffs to include (default: 3) */
  handoffLimit?: number;
  /** Whether to include working files from ledger (default: true) */
  includeWorkingFiles?: boolean;
}

/**
 * SessionStart hook result with injected context
 */
export interface SessionStartResult extends HookResult {
  /** Context to inject into the session */
  context?: {
    ledger?: {
      goal: string;
      now: string;
      next: string[];
      workingFiles: string[];
    };
    recentHandoffs?: Array<{
      sessionId: string;
      summary: string;
      timestamp: string;
    }>;
  };
}

/**
 * Create the SessionStart hook
 *
 * This hook runs at the beginning of each session and:
 * 1. Loads the continuity ledger to restore session state
 * 2. Retrieves recent handoffs for historical context
 * 3. Generates a context message for the agent
 */
export function createSessionStartHook(
  config: SessionStartHookConfig
): HookDefinition {
  const {
    ledgerManager,
    handoffManager,
    handoffLimit = 3,
    includeWorkingFiles = true,
  } = config;

  return {
    name: 'builtin:session-start',
    type: 'SessionStart',
    description: 'Loads ledger and handoff context at session start',
    priority: 100, // Run early to set up context

    handler: async (ctx): Promise<SessionStartResult> => {
      const context = ctx as SessionStartHookContext;
      logger.info('SessionStart hook executing', {
        sessionId: context.sessionId,
        workingDirectory: context.workingDirectory,
      });

      const contextParts: string[] = [];
      const resultContext: SessionStartResult['context'] = {};

      // 1. Load ledger
      try {
        const ledger = await ledgerManager.load();

        if (ledger.goal || ledger.now || ledger.next.length > 0) {
          resultContext.ledger = {
            goal: ledger.goal,
            now: ledger.now,
            next: ledger.next,
            workingFiles: includeWorkingFiles ? ledger.workingFiles : [],
          };

          // Build context message
          contextParts.push('## Session Context (from Continuity Ledger)\n');

          if (ledger.goal) {
            contextParts.push(`**Goal**: ${ledger.goal}`);
          }

          if (ledger.now) {
            contextParts.push(`**Currently working on**: ${ledger.now}`);
          }

          if (ledger.next.length > 0) {
            contextParts.push(`**Next steps**: ${ledger.next.slice(0, 5).join(', ')}`);
          }

          if (includeWorkingFiles && ledger.workingFiles.length > 0) {
            contextParts.push(`**Working files**: ${ledger.workingFiles.join(', ')}`);
          }

          if (ledger.constraints.length > 0) {
            contextParts.push(`**Constraints**: ${ledger.constraints.join('; ')}`);
          }

          contextParts.push('');
          logger.debug('Ledger loaded', { goal: ledger.goal, now: ledger.now });
        }
      } catch (error) {
        logger.warn('Failed to load ledger', {
          error: error instanceof Error ? error.message : String(error),
        });
      }

      // 2. Load recent handoffs
      if (handoffManager) {
        try {
          const handoffs = await handoffManager.getRecent(handoffLimit);

          if (handoffs.length > 0) {
            resultContext.recentHandoffs = handoffs.map(h => ({
              sessionId: h.sessionId,
              summary: h.summary,
              timestamp: h.timestamp.toISOString(),
            }));

            contextParts.push('## Previous Session Summaries\n');

            for (const handoff of handoffs) {
              contextParts.push(`### ${handoff.timestamp.toLocaleDateString()}`);
              contextParts.push(handoff.summary);

              if (handoff.nextSteps.length > 0) {
                contextParts.push(`**Pending**: ${handoff.nextSteps.slice(0, 3).join(', ')}`);
              }

              if (handoff.patterns.length > 0) {
                contextParts.push(`**Patterns**: ${handoff.patterns.join(', ')}`);
              }

              contextParts.push('');
            }

            logger.debug('Handoffs loaded', { count: handoffs.length });
          }
        } catch (error) {
          logger.warn('Failed to load handoffs', {
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }

      // 3. Check for parent handoff continuation
      if (context.parentHandoffId && handoffManager) {
        try {
          const parentHandoff = await handoffManager.get(context.parentHandoffId);

          if (parentHandoff) {
            contextParts.push('## Continuing from Previous Session\n');
            contextParts.push(`**Previous state**: ${parentHandoff.currentState}`);

            if (parentHandoff.blockers.length > 0) {
              contextParts.push(`**Blockers to address**: ${parentHandoff.blockers.join(', ')}`);
            }

            if (parentHandoff.nextSteps.length > 0) {
              contextParts.push(`**Recommended next steps**:`);
              for (const step of parentHandoff.nextSteps) {
                contextParts.push(`- ${step}`);
              }
            }

            contextParts.push('');
            logger.info('Parent handoff loaded', { handoffId: context.parentHandoffId });
          }
        } catch (error) {
          logger.warn('Failed to load parent handoff', {
            handoffId: context.parentHandoffId,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }

      // Return result with context
      const message = contextParts.length > 0 ? contextParts.join('\n') : undefined;

      return {
        action: message ? 'modify' : 'continue',
        message,
        context: Object.keys(resultContext).length > 0 ? resultContext : undefined,
        modifications: message ? { systemContext: message } : undefined,
      };
    },
  };
}

/**
 * Default export for convenience
 */
export default createSessionStartHook;
