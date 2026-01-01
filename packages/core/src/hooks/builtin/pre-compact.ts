/**
 * @fileoverview PreCompact Built-in Hook
 *
 * Executes before context compaction. Responsibilities:
 * - Auto-generate handoff to preserve session knowledge
 * - Update ledger with current progress
 * - Optionally block compaction until handoff is complete
 *
 * This hook prevents knowledge loss during context window management.
 *
 * @example
 * ```typescript
 * import { createPreCompactHook } from './pre-compact';
 *
 * const hook = createPreCompactHook({
 *   handoffManager,
 *   ledgerManager,
 *   blockUntilHandoff: true,
 * });
 *
 * engine.register(hook);
 * ```
 */

import type {
  HookDefinition,
  PreCompactHookContext,
  HookResult,
} from '../types.js';
import type { LedgerManager } from '../../memory/ledger-manager.js';
import type { HandoffManager, Handoff } from '../../memory/handoff-manager.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('hooks:pre-compact');

/**
 * Configuration for PreCompact hook
 */
export interface PreCompactHookConfig {
  /** Handoff manager for persistence */
  handoffManager: HandoffManager;
  /** Ledger manager for session state */
  ledgerManager?: LedgerManager;
  /** Block compaction until handoff is created (default: false) */
  blockUntilHandoff?: boolean;
  /** Token threshold to trigger auto-handoff (default: 80% of target) */
  autoHandoffThreshold?: number;
  /** Custom context summarizer for handoff */
  contextSummarizer?: (context: PreCompactContext) => Promise<string>;
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
 * This hook runs before context compaction and:
 * 1. Creates a checkpoint handoff preserving current session state
 * 2. Updates the ledger with progress so far
 * 3. Generates a summary that will survive compaction
 * 4. Optionally blocks until handoff is safely created
 */
export function createPreCompactHook(
  config: PreCompactHookConfig
): HookDefinition {
  const {
    handoffManager,
    ledgerManager,
    blockUntilHandoff = false,
    autoHandoffThreshold = 0.8,
    contextSummarizer,
  } = config;

  return {
    name: 'builtin:pre-compact',
    type: 'PreCompact',
    description: 'Creates handoff checkpoint before context compaction',
    priority: 100, // Run early to capture state before compaction

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as PreCompactContext;
      logger.info('PreCompact hook executing', {
        sessionId: context.sessionId,
        currentTokens: context.currentTokens,
        targetTokens: context.targetTokens,
        reason: context.reason,
      });

      const tokenRatio = context.currentTokens / context.targetTokens;

      // Check if we should auto-handoff
      if (tokenRatio < autoHandoffThreshold) {
        logger.debug('Below auto-handoff threshold, skipping', {
          ratio: tokenRatio,
          threshold: autoHandoffThreshold,
        });
        return { action: 'continue' };
      }

      try {
        // 1. Get current ledger state
        let ledgerState: {
          goal?: string;
          now?: string;
          done?: string[];
          next?: string[];
          decisions?: Array<{ choice: string; reason: string }>;
          workingFiles?: string[];
        } = {};

        if (ledgerManager) {
          try {
            const ledger = await ledgerManager.get();
            ledgerState = {
              goal: ledger.goal,
              now: ledger.now,
              done: ledger.done,
              next: ledger.next,
              decisions: ledger.decisions,
              workingFiles: ledger.workingFiles,
            };
          } catch (error) {
            logger.warn('Failed to get ledger', {
              error: error instanceof Error ? error.message : String(error),
            });
          }
        }

        // 2. Generate summary
        const summary = contextSummarizer
          ? await contextSummarizer(context)
          : generateCompactionSummary(context, ledgerState);

        // 3. Create checkpoint handoff
        const handoff: Omit<Handoff, 'id'> = {
          sessionId: context.sessionId,
          timestamp: new Date(),
          summary,
          codeChanges: [], // Could be populated from PostToolUse tracking
          currentState: `Pre-compaction checkpoint at ${context.currentTokens} tokens`,
          blockers: [],
          nextSteps: ledgerState.next ?? [],
          patterns: extractDecisionPatterns(ledgerState.decisions ?? []),
          metadata: {
            type: 'compaction_checkpoint',
            tokensAtCompaction: context.currentTokens,
            targetTokens: context.targetTokens,
            reason: context.reason ?? 'token_limit',
          },
        };

        const handoffId = await handoffManager.create(handoff);
        logger.info('Compaction handoff created', {
          handoffId,
          sessionId: context.sessionId,
        });

        // 4. Update ledger with checkpoint marker
        if (ledgerManager) {
          try {
            await ledgerManager.addDone(`[Checkpoint] Context compacted at ${context.currentTokens} tokens`);
          } catch (error) {
            logger.warn('Failed to update ledger', {
              error: error instanceof Error ? error.message : String(error),
            });
          }
        }

        // 5. Generate continuation context
        const continuationContext = generateContinuationContext(ledgerState, handoffId);

        return {
          action: blockUntilHandoff ? 'modify' : 'continue',
          message: continuationContext,
          modifications: {
            handoffId,
            compactionHandoffCreated: true,
            continuationContext,
          },
        };
      } catch (error) {
        logger.error('Failed to create compaction handoff', {
          sessionId: context.sessionId,
          error: error instanceof Error ? error.message : String(error),
        });

        if (blockUntilHandoff) {
          return {
            action: 'block',
            reason: `Cannot compact without handoff: ${error instanceof Error ? error.message : String(error)}`,
          };
        }

        return { action: 'continue' };
      }
    },
  };
}

/**
 * Generate summary for compaction checkpoint
 */
function generateCompactionSummary(
  context: PreCompactContext,
  ledgerState: {
    goal?: string;
    now?: string;
    done?: string[];
  }
): string {
  const parts: string[] = [];

  parts.push(`Context compaction checkpoint (${context.currentTokens}/${context.targetTokens} tokens)`);

  if (ledgerState.goal) {
    parts.push(`Goal: ${ledgerState.goal}`);
  }

  if (ledgerState.now) {
    parts.push(`Working on: ${ledgerState.now}`);
  }

  if (ledgerState.done && ledgerState.done.length > 0) {
    const recentDone = ledgerState.done.slice(-5);
    parts.push(`Recent completions: ${recentDone.join(', ')}`);
  }

  if (context.toolCalls && context.toolCalls.length > 0) {
    const recentTools = context.toolCalls.slice(-5).map(t => t.name);
    parts.push(`Recent tools: ${recentTools.join(', ')}`);
  }

  return parts.join('. ');
}

/**
 * Extract patterns from decisions
 */
function extractDecisionPatterns(
  decisions: Array<{ choice: string; reason: string }>
): string[] {
  return decisions.slice(-3).map(d =>
    d.reason ? `${d.choice}: ${d.reason}` : d.choice
  );
}

/**
 * Generate context for continuation after compaction
 */
function generateContinuationContext(
  ledgerState: {
    goal?: string;
    now?: string;
    next?: string[];
    workingFiles?: string[];
  },
  handoffId: string
): string {
  const parts: string[] = [];

  parts.push('## Session Continuation (Post-Compaction)\n');
  parts.push(`*Checkpoint saved: ${handoffId}*\n`);

  if (ledgerState.goal) {
    parts.push(`**Goal**: ${ledgerState.goal}`);
  }

  if (ledgerState.now) {
    parts.push(`**Continue with**: ${ledgerState.now}`);
  }

  if (ledgerState.next && ledgerState.next.length > 0) {
    parts.push(`**Next steps**: ${ledgerState.next.slice(0, 3).join(', ')}`);
  }

  if (ledgerState.workingFiles && ledgerState.workingFiles.length > 0) {
    parts.push(`**Working files**: ${ledgerState.workingFiles.join(', ')}`);
  }

  return parts.join('\n');
}

/**
 * Default export for convenience
 */
export default createPreCompactHook;
