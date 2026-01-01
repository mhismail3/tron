/**
 * @fileoverview SessionEnd Built-in Hook
 *
 * Executes when a session ends. Responsibilities:
 * - Generate handoff document from session
 * - Extract patterns and learnings
 * - Update project memory with decisions
 * - Clean up session resources
 *
 * This hook ensures knowledge is preserved across sessions.
 *
 * @example
 * ```typescript
 * import { createSessionEndHook } from './session-end';
 *
 * const hook = createSessionEndHook({
 *   handoffManager,
 *   ledgerManager,
 * });
 *
 * engine.register(hook);
 * ```
 */

import type {
  HookDefinition,
  SessionEndHookContext,
  HookResult,
} from '../types.js';
import type { LedgerManager, Ledger } from '../../memory/ledger-manager.js';
import type { HandoffManager, Handoff, CodeChange } from '../../memory/handoff-manager.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('hooks:session-end');

/**
 * Configuration for SessionEnd hook
 */
export interface SessionEndHookConfig {
  /** Handoff manager for persistence */
  handoffManager: HandoffManager;
  /** Ledger manager for session state */
  ledgerManager?: LedgerManager;
  /** Minimum message count to create handoff (default: 2) */
  minMessagesForHandoff?: number;
  /** Whether to clear ledger after handoff (default: false) */
  clearLedgerOnEnd?: boolean;
  /** Custom summary generator */
  summaryGenerator?: (context: SessionEndContext) => Promise<string>;
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
 * This hook runs when a session ends and:
 * 1. Generates a handoff document summarizing the session
 * 2. Extracts patterns from successful operations
 * 3. Records any blockers or incomplete work
 * 4. Optionally clears the ledger for the next session
 */
export function createSessionEndHook(
  config: SessionEndHookConfig
): HookDefinition {
  const {
    handoffManager,
    ledgerManager,
    minMessagesForHandoff = 2,
    clearLedgerOnEnd = false,
    summaryGenerator,
  } = config;

  return {
    name: 'builtin:session-end',
    type: 'SessionEnd',
    description: 'Creates handoff and extracts learnings at session end',
    priority: 100, // Run early to capture state

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as SessionEndContext;
      logger.info('SessionEnd hook executing', {
        sessionId: context.sessionId,
        messageCount: context.messageCount,
        toolCallCount: context.toolCallCount,
      });

      // Skip handoff for very short sessions
      if (context.messageCount < minMessagesForHandoff) {
        logger.debug('Session too short for handoff', {
          messageCount: context.messageCount,
          minimum: minMessagesForHandoff,
        });
        return { action: 'continue' };
      }

      try {
        // 1. Get ledger state if available
        let ledger: Ledger | undefined;
        if (ledgerManager) {
          try {
            ledger = await ledgerManager.get();
          } catch (error) {
            logger.warn('Failed to get ledger', {
              error: error instanceof Error ? error.message : String(error),
            });
          }
        }

        // 2. Generate summary
        const summary = summaryGenerator
          ? await summaryGenerator(context)
          : generateDefaultSummary(context, ledger);

        // 3. Extract code changes
        const codeChanges = extractCodeChanges(context);

        // 4. Determine current state
        const currentState = determineCurrentState(context, ledger);

        // 5. Identify blockers
        const blockers = identifyBlockers(context, ledger);

        // 6. Determine next steps
        const nextSteps = determineNextSteps(context, ledger);

        // 7. Extract patterns
        const patterns = extractPatterns(context, ledger);

        // 8. Create handoff
        const handoff: Omit<Handoff, 'id'> = {
          sessionId: context.sessionId,
          timestamp: new Date(),
          summary,
          codeChanges,
          currentState,
          blockers,
          nextSteps,
          patterns,
          metadata: {
            messageCount: context.messageCount,
            toolCallCount: context.toolCallCount,
            outcome: context.outcome ?? 'completed',
          },
        };

        const handoffId = await handoffManager.create(handoff);
        logger.info('Handoff created', { handoffId, sessionId: context.sessionId });

        // 9. Optionally clear ledger
        if (clearLedgerOnEnd && ledgerManager) {
          await ledgerManager.clear(true); // Preserve goal
          logger.debug('Ledger cleared');
        }

        return {
          action: 'continue',
          message: `Session handoff created: ${handoffId}`,
          modifications: {
            handoffId,
            handoffCreated: true,
          },
        };
      } catch (error) {
        logger.error('Failed to create handoff', {
          sessionId: context.sessionId,
          error: error instanceof Error ? error.message : String(error),
        });

        return {
          action: 'continue', // Don't block session end on handoff failure
          reason: `Handoff creation failed: ${error instanceof Error ? error.message : String(error)}`,
        };
      }
    },
  };
}

/**
 * Generate default summary from session context
 */
function generateDefaultSummary(
  context: SessionEndContext,
  ledger?: Ledger
): string {
  const parts: string[] = [];

  // Use ledger goal if available
  if (ledger?.goal) {
    parts.push(`Goal: ${ledger.goal}`);
  }

  // Add what was worked on
  if (ledger?.now) {
    parts.push(`Worked on: ${ledger.now}`);
  }

  // Summarize completed items
  if (ledger?.done && ledger.done.length > 0) {
    parts.push(`Completed: ${ledger.done.slice(-3).join(', ')}`);
  }

  // Add tool call summary
  if (context.toolCallCount > 0) {
    parts.push(`Made ${context.toolCallCount} tool calls`);
  }

  // Add outcome
  if (context.outcome === 'error' && context.error) {
    parts.push(`Ended with error: ${context.error}`);
  }

  return parts.join('. ') || 'Session completed';
}

/**
 * Extract code changes from session context
 */
function extractCodeChanges(context: SessionEndContext): CodeChange[] {
  if (!context.filesModified) return [];

  return context.filesModified.map(file => ({
    file: file.path,
    description: `File ${file.operation}d`,
    operation: file.operation,
  }));
}

/**
 * Determine current state from context
 */
function determineCurrentState(
  context: SessionEndContext,
  ledger?: Ledger
): string {
  if (context.outcome === 'error') {
    return `Session ended with error: ${context.error ?? 'Unknown error'}`;
  }

  if (context.outcome === 'aborted') {
    return 'Session was aborted by user';
  }

  if (ledger?.now) {
    return `Last working on: ${ledger.now}`;
  }

  return 'Session completed normally';
}

/**
 * Identify blockers from session
 */
function identifyBlockers(
  context: SessionEndContext,
  _ledger?: Ledger
): string[] {
  const blockers: string[] = [];

  if (context.outcome === 'error' && context.error) {
    blockers.push(`Error encountered: ${context.error}`);
  }

  // Could be extended to analyze tool failures, etc.

  return blockers;
}

/**
 * Determine next steps from context
 */
function determineNextSteps(
  context: SessionEndContext,
  ledger?: Ledger
): string[] {
  const nextSteps: string[] = [];

  // Carry over from ledger
  if (ledger?.next && ledger.next.length > 0) {
    nextSteps.push(...ledger.next);
  }

  // Add error recovery if needed
  if (context.outcome === 'error') {
    nextSteps.unshift('Investigate and fix the error from previous session');
  }

  return nextSteps.slice(0, 5); // Limit to 5
}

/**
 * Extract patterns from successful session
 */
function extractPatterns(
  _context: SessionEndContext,
  ledger?: Ledger
): string[] {
  const patterns: string[] = [];

  // Extract from ledger decisions
  if (ledger?.decisions && ledger.decisions.length > 0) {
    for (const decision of ledger.decisions.slice(-3)) {
      patterns.push(`${decision.choice}: ${decision.reason}`);
    }
  }

  return patterns;
}

/**
 * Default export for convenience
 */
export default createSessionEndHook;
