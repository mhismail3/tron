/**
 * @fileoverview Compaction Handler Module
 *
 * Manages context compaction (summarization) to keep conversation
 * history within token limits. Provides automatic compaction when
 * thresholds are exceeded.
 */

import type { ContextManager } from '../context/context-manager.js';
import type { Summarizer } from '../context/summarizer.js';
import type {
  CompactionHandler as ICompactionHandler,
  CompactionHandlerDependencies,
  CompactionAttemptResult,
  EventEmitter,
} from './internal-types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('agent:compaction');

/** Valid reasons for compaction */
type CompactionReason = 'pre_turn_guardrail' | 'threshold_exceeded' | 'manual';

/**
 * Compaction handler implementation
 */
export class AgentCompactionHandler implements ICompactionHandler {
  private readonly contextManager: ContextManager;
  private readonly eventEmitter: EventEmitter;
  private readonly sessionId: string;

  private summarizer: Summarizer | null = null;
  private autoCompactionEnabled: boolean = true;

  constructor(deps: CompactionHandlerDependencies) {
    this.contextManager = deps.contextManager;
    this.eventEmitter = deps.eventEmitter;
    this.sessionId = deps.sessionId;
  }

  /**
   * Set the summarizer for compaction
   */
  setSummarizer(summarizer: Summarizer): void {
    this.summarizer = summarizer;
    logger.info('Summarizer configured', { sessionId: this.sessionId });
  }

  /**
   * Get the current summarizer (for advanced use cases)
   */
  getSummarizer(): Summarizer | null {
    return this.summarizer;
  }

  /**
   * Check if auto-compaction is available
   */
  canAutoCompact(): boolean {
    return this.autoCompactionEnabled && this.summarizer !== null;
  }

  /**
   * Enable/disable auto-compaction
   */
  setAutoCompaction(enabled: boolean): void {
    this.autoCompactionEnabled = enabled;
    logger.info('Auto-compaction toggled', {
      sessionId: this.sessionId,
      enabled,
    });
  }

  /**
   * Attempt compaction if needed
   * @param reason - The reason for compaction (for logging/events)
   */
  async attemptCompaction(reason: CompactionReason): Promise<CompactionAttemptResult> {
    if (!this.canAutoCompact() || !this.summarizer) {
      return {
        success: false,
        error: 'Auto-compaction not available (no summarizer or disabled)',
      };
    }

    const tokensBefore = this.contextManager.getCurrentTokens();

    logger.info('Attempting auto-compaction', {
      sessionId: this.sessionId,
      reason,
      tokensBefore,
      contextLimit: this.contextManager.getContextLimit(),
    });

    this.eventEmitter.emit({
      type: 'compaction_start',
      sessionId: this.sessionId,
      timestamp: new Date().toISOString(),
      reason,
      tokensBefore,
    });

    try {
      const result = await this.contextManager.executeCompaction({
        summarizer: this.summarizer,
      });

      this.eventEmitter.emit({
        type: 'compaction_complete',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        success: result.success,
        tokensBefore: result.tokensBefore,
        tokensAfter: result.tokensAfter,
        compressionRatio: result.compressionRatio,
        reason,
      });

      if (result.success) {
        logger.info('Auto-compaction successful', {
          sessionId: this.sessionId,
          tokensBefore: result.tokensBefore,
          tokensAfter: result.tokensAfter,
          compressionRatio: result.compressionRatio,
        });
      } else {
        logger.warn('Auto-compaction completed but did not meet target', {
          sessionId: this.sessionId,
        });
      }

      return {
        success: result.success,
        tokensBefore: result.tokensBefore,
        tokensAfter: result.tokensAfter,
        compressionRatio: result.compressionRatio,
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);

      this.eventEmitter.emit({
        type: 'compaction_complete',
        sessionId: this.sessionId,
        timestamp: new Date().toISOString(),
        success: false,
        tokensBefore,
        tokensAfter: tokensBefore,
        compressionRatio: 1,
        reason,
      });

      logger.error('Auto-compaction failed', { error: errorMessage });

      return {
        success: false,
        error: errorMessage,
        tokensBefore,
      };
    }
  }

  /**
   * Check if compaction is needed before a turn
   * Returns whether the turn can proceed and if compaction should be attempted
   */
  validatePreTurn(estimatedResponseTokens: number = 4000): {
    canProceed: boolean;
    needsCompaction: boolean;
    error?: string;
  } {
    const validation = this.contextManager.canAcceptTurn({ estimatedResponseTokens });

    if (!validation.canProceed) {
      if (this.canAutoCompact()) {
        // Can attempt compaction
        return { canProceed: false, needsCompaction: true };
      } else {
        // Cannot proceed and cannot compact
        return {
          canProceed: false,
          needsCompaction: false,
          error: 'Context limit exceeded. Enable auto-compaction or clear messages.',
        };
      }
    }

    if (validation.needsCompaction && this.canAutoCompact()) {
      // Can proceed but compaction is recommended
      logger.debug('Context approaching threshold', {
        sessionId: this.sessionId,
        thresholdLevel: this.contextManager.getSnapshot().thresholdLevel,
      });
    }

    return { canProceed: true, needsCompaction: validation.needsCompaction };
  }
}

/**
 * Create a compaction handler instance
 */
export function createCompactionHandler(deps: CompactionHandlerDependencies): AgentCompactionHandler {
  return new AgentCompactionHandler(deps);
}
