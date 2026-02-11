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
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '@infrastructure/logging/index.js';
import { KeywordSummarizer, type Summarizer } from '@context/summarizer.js';
import type {
  ContextSnapshot,
  DetailedContextSnapshot,
  PreTurnValidation,
  CompactionPreview,
  CompactionResult,
} from '@context/context-manager.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';

const logger = createLogger('context-ops');

// =============================================================================
// Types
// =============================================================================

export interface ContextOpsConfig {
  /** Active session store */
  sessionStore: ActiveSessionStore;
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
    const active = this.config.sessionStore.get(sessionId);
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
    const active = this.config.sessionStore.get(sessionId);
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

    // Augment messages with eventIds from SessionContext tracking
    // The messageEventIds array parallels the context manager's messages array
    const messageEventIds = active.sessionContext.getMessageEventIds();
    for (let i = 0; i < snapshot.messages.length; i++) {
      const eventId = messageEventIds[i];
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
        tokens: s.tokens,
      })),
    } as DetailedContextSnapshot & {
      addedSkills: typeof addedSkills;
      memory?: { count: number; tokens: number; entries: Array<{ title: string; content: string }> };
    };

    // Include memory info if memory was auto-injected
    const memoryContent = active.agent.getContextManager().getMemoryContent();
    if (memoryContent) {
      // Parse entries by splitting on ### headings
      const entries: Array<{ title: string; content: string }> = [];
      const sections = memoryContent.split(/^### /gm).slice(1); // skip preamble
      for (const section of sections) {
        const newlineIdx = section.indexOf('\n');
        const title = newlineIdx >= 0 ? section.slice(0, newlineIdx).trim() : section.trim();
        const content = newlineIdx >= 0 ? section.slice(newlineIdx + 1).trim() : '';
        entries.push({ title, content });
      }
      result.memory = {
        count: Math.max(entries.length, 1),
        tokens: Math.ceil(memoryContent.length / 4),
        entries,
      };
    }

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
    const active = this.config.sessionStore.get(sessionId);
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
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      const err = new Error('Session not active');
      (err as any).code = 'SESSION_NOT_ACTIVE';
      throw err;
    }

    const summarizer = this.getSummarizer(sessionId);
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
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      const err = new Error('Session not active');
      (err as any).code = 'SESSION_NOT_ACTIVE';
      throw err;
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();
    const summarizer = this.getSummarizer(sessionId);

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
    const active = this.config.sessionStore.get(sessionId);
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
   *
   * Returns incomplete todos that were cleared (for backlogging by caller).
   */
  async clearContext(sessionId: string): Promise<{
    success: boolean;
    tokensBefore: number;
    tokensAfter: number;
    clearedTodos: Array<{ id: string; content: string; status: string; source: string }>;
  }> {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      const err = new Error('Session not active');
      (err as any).code = 'SESSION_NOT_ACTIVE';
      throw err;
    }

    const cm = active.agent.getContextManager();
    const tokensBefore = cm.getCurrentTokens();

    // Clear all messages from context manager
    cm.clearMessages();

    // Clear skill tracker (skills don't survive context clear)
    active.skillTracker.clear();

    // Clear todo tracker and get incomplete tasks for backlogging
    const incompleteTodos = active.todoTracker.clear();
    const clearedTodos = incompleteTodos.map(t => ({
      id: t.id,
      content: t.content,
      status: t.status,
      source: t.source,
    }));

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
      clearedTodosCount: clearedTodos.length,
    });

    // Emit context_cleared event for WebSocket broadcast
    this.config.emit('context_cleared', {
      sessionId,
      tokensBefore,
      tokensAfter,
      clearedTodos,
    });

    return {
      success: true,
      tokensBefore,
      tokensAfter,
      clearedTodos,
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Get a summarizer instance for compaction operations.
   * Prefers the agent's LLM summarizer if available.
   */
  private getSummarizer(sessionId: string): Summarizer {
    const active = this.config.sessionStore.get(sessionId);
    return active?.agent.getSummarizer() ?? new KeywordSummarizer();
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createContextOps(config: ContextOpsConfig): ContextOps {
  return new ContextOps(config);
}
