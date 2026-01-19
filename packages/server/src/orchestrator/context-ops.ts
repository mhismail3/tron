/**
 * @fileoverview Context Operations
 *
 * Extracts context management logic from EventStoreOrchestrator:
 * - Context snapshots (basic and detailed)
 * - Compaction operations (preview, execute)
 * - Pre-turn validation
 * - Context clearing
 *
 * Phase 6 of orchestrator refactoring.
 */
import {
  createLogger,
  KeywordSummarizer,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type Summarizer,
} from '@tron/core';
import type { ActiveSession } from './types.js';

const logger = createLogger('context-ops');

// =============================================================================
// Types
// =============================================================================

export interface ContextOpsConfig {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Emit event */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// ContextOps Class
// =============================================================================

export class ContextOps {
  private config: ContextOpsConfig;

  constructor(config: ContextOpsConfig) {
    this.config = config;
  }

  // ===========================================================================
  // Context Snapshots
  // ===========================================================================

  /**
   * Get the current context snapshot for a session.
   * Returns token usage, limits, and threshold levels.
   * For inactive sessions, returns a default snapshot with zero usage.
   */
  getContextSnapshot(sessionId: string): ContextSnapshot {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      // Return default snapshot for inactive sessions
      // Use default model's context limit (200k for Claude Sonnet 4)
      return {
        currentTokens: 0,
        contextLimit: 200_000,
        usagePercent: 0,
        thresholdLevel: 'normal',
        breakdown: {
          systemPrompt: 0,
          tools: 0,
          rules: 0,
          messages: 0,
        },
      };
    }
    return active.agent.getContextManager().getSnapshot();
  }

  /**
   * Get detailed context snapshot with per-message token breakdown.
   * Returns empty messages array for inactive sessions.
   */
  getDetailedContextSnapshot(sessionId: string): DetailedContextSnapshot {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      // Return default snapshot for inactive sessions
      return {
        currentTokens: 0,
        contextLimit: 200_000,
        usagePercent: 0,
        thresholdLevel: 'normal',
        breakdown: {
          systemPrompt: 0,
          tools: 0,
          rules: 0,
          messages: 0,
        },
        messages: [],
        systemPromptContent: '',
        toolsContent: [],
      };
    }
    const snapshot = active.agent.getContextManager().getDetailedSnapshot();

    // Augment messages with eventIds from session tracking
    // The messageEventIds array parallels the context manager's messages array
    for (let i = 0; i < snapshot.messages.length; i++) {
      const eventId = active.messageEventIds[i];
      const message = snapshot.messages[i];
      if (eventId && message) {
        message.eventId = eventId;
      }
    }

    // Include rules data from the session's rules tracker
    if (active.rulesTracker.hasRules()) {
      const rulesFiles = active.rulesTracker.getRulesFiles();
      snapshot.rules = {
        files: rulesFiles.map(f => ({
          path: f.path,
          relativePath: f.relativePath,
          level: f.level,
          depth: f.depth,
        })),
        totalFiles: rulesFiles.length,
        tokens: active.rulesTracker.getMergedTokens(),
      };
    }

    // Include added skills from the session's skill tracker
    const addedSkills = active.skillTracker.getAddedSkills();
    const result = {
      ...snapshot,
      addedSkills: addedSkills.map(s => ({
        name: s.name,
        source: s.source,
        addedVia: s.addedVia,
        eventId: s.eventId,
      })),
    };

    return result;
  }

  // ===========================================================================
  // Compaction
  // ===========================================================================

  /**
   * Check if a session needs compaction based on context threshold.
   * Returns false for inactive sessions (nothing to compact).
   */
  shouldCompact(sessionId: string): boolean {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      return false; // Inactive sessions don't need compaction
    }
    return active.agent.getContextManager().shouldCompact();
  }

  /**
   * Preview compaction without executing it.
   * Returns estimated token reduction and generated summary.
   */
  async previewCompaction(sessionId: string): Promise<CompactionPreview> {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const summarizer = this.getSummarizer();
    return active.agent.getContextManager().previewCompaction({ summarizer });
  }

  /**
   * Execute compaction on a session.
   * Stores compact.boundary and compact.summary events in EventStore.
   */
  async confirmCompaction(
    sessionId: string,
    opts?: { editedSummary?: string; reason?: string }
  ): Promise<CompactionResult> {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();
    const summarizer = this.getSummarizer();

    const result = await cm.executeCompaction({
      summarizer,
      editedSummary: opts?.editedSummary,
    });

    // Clear skill tracker (skills don't survive compaction)
    active.skillTracker.clear();

    // Store compaction events in EventStore (linearized via SessionContext)
    const compactionReason = opts?.reason || 'manual';
    await active.sessionContext!.appendMultipleEvents([
      {
        type: 'compact.boundary',
        payload: {
          originalTokens: tokensBefore,
          compactedTokens: result.tokensAfter,
          compressionRatio: result.compressionRatio,
          reason: compactionReason,
          // Include summary in boundary event for easier iOS access
          summary: result.summary,
        },
      },
      {
        type: 'compact.summary',
        payload: {
          summary: result.summary,
          keyDecisions: result.extractedData?.keyDecisions?.map(d => d.decision),
          filesModified: result.extractedData?.filesModified,
        },
      },
    ]);

    logger.info('Compaction completed', {
      sessionId,
      tokensBefore,
      tokensAfter: result.tokensAfter,
      compressionRatio: result.compressionRatio,
    });

    // Emit compaction_completed event
    this.config.emit('compaction_completed', {
      sessionId,
      tokensBefore,
      tokensAfter: result.tokensAfter,
      compressionRatio: result.compressionRatio,
      summary: result.summary,
    });

    return result;
  }

  // ===========================================================================
  // Pre-turn Validation
  // ===========================================================================

  /**
   * Pre-turn validation to check if a turn can proceed.
   * Returns whether compaction is needed and estimated token usage.
   * Inactive sessions can always accept turns (they'll be activated first).
   */
  canAcceptTurn(
    sessionId: string,
    opts: { estimatedResponseTokens: number }
  ): PreTurnValidation {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      // Inactive sessions can always accept turns - they'll be activated first
      return {
        canProceed: true,
        needsCompaction: false,
        wouldExceedLimit: false,
        currentTokens: 0,
        estimatedAfterTurn: opts.estimatedResponseTokens,
        contextLimit: 200_000,
      };
    }
    return active.agent.getContextManager().canAcceptTurn(opts);
  }

  // ===========================================================================
  // Context Clearing
  // ===========================================================================

  /**
   * Clear all messages from context.
   * Unlike compaction, no summary is preserved - messages are just cleared.
   * Stores a context.cleared event in EventStore.
   */
  async clearContext(sessionId: string): Promise<{
    success: boolean;
    tokensBefore: number;
    tokensAfter: number;
  }> {
    const active = this.config.getActiveSession(sessionId);
    if (!active) {
      throw new Error('Session not active');
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();

    // Clear all messages from context manager
    cm.clearMessages();

    // Clear skill tracker (skills don't survive context clear)
    active.skillTracker.clear();

    const tokensAfter = cm.getCurrentTokens();

    // Store context.cleared event in EventStore (linearized via SessionContext)
    await active.sessionContext!.appendEvent('context.cleared', {
      tokensBefore,
      tokensAfter,
      reason: 'manual',
    });

    logger.info('Context cleared', {
      sessionId,
      tokensBefore,
      tokensAfter,
      tokensFreed: tokensBefore - tokensAfter,
    });

    // Emit context_cleared event for WebSocket broadcast
    this.config.emit('context_cleared', {
      sessionId,
      tokensBefore,
      tokensAfter,
    });

    return {
      success: true,
      tokensBefore,
      tokensAfter,
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Get a summarizer instance for compaction operations.
   */
  private getSummarizer(): Summarizer {
    // Use KeywordSummarizer for now - in production this would use LLM
    return new KeywordSummarizer();
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createContextOps(config: ContextOpsConfig): ContextOps {
  return new ContextOps(config);
}
