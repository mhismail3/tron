/**
 * @fileoverview Context Service
 *
 * Provides context management with a clean interface.
 * Wraps the ContextOps implementation with a formal service contract.
 *
 * ## Responsibilities
 * - Context snapshots (basic and detailed)
 * - Compaction operations (preview, execute)
 * - Pre-turn validation
 * - Context clearing
 *
 * ## Usage
 * ```typescript
 * const contextService = createContextService(deps);
 * const snapshot = contextService.getSnapshot(sessionId);
 * if (contextService.shouldCompact(sessionId)) {
 *   await contextService.confirmCompaction(sessionId);
 * }
 * ```
 */
import {
  ContextOps,
  createContextOps,
  type ContextOpsConfig,
} from '../../orchestrator/operations/context-ops.js';
import type {
  ContextSnapshot,
  DetailedContextSnapshot,
  PreTurnValidation,
  CompactionPreview,
  CompactionResult,
} from '../../context/types.js';

// =============================================================================
// Service Interface
// =============================================================================

/**
 * Context service interface - clean contract for context management.
 */
export interface ContextService {
  /**
   * Get the current context snapshot for a session.
   * Returns token usage, limits, and threshold levels.
   * @param sessionId - Session ID
   * @returns Context snapshot with usage information
   */
  getSnapshot(sessionId: string): ContextSnapshot;

  /**
   * Get detailed context snapshot with per-message token breakdown.
   * @param sessionId - Session ID
   * @returns Detailed snapshot including individual message tokens
   */
  getDetailedSnapshot(sessionId: string): DetailedContextSnapshot;

  /**
   * Check if a session needs compaction based on context threshold.
   * @param sessionId - Session ID
   * @returns True if compaction is recommended
   */
  shouldCompact(sessionId: string): boolean;

  /**
   * Preview compaction without executing it.
   * Returns estimated token reduction and generated summary.
   * @param sessionId - Session ID
   * @returns Compaction preview with estimated results
   */
  previewCompaction(sessionId: string): Promise<CompactionPreview>;

  /**
   * Execute compaction on a session.
   * Stores compact.boundary and compact.summary events in EventStore.
   * @param sessionId - Session ID
   * @param options - Optional edited summary and reason
   * @returns Compaction result with actual token reduction
   */
  confirmCompaction(sessionId: string, options?: CompactionOptions): Promise<CompactionResult>;

  /**
   * Pre-turn validation to check if a turn can proceed.
   * Returns whether compaction is needed and estimated token usage.
   * @param sessionId - Session ID
   * @param options - Validation options including estimated response tokens
   * @returns Validation result with compaction recommendation
   */
  canAcceptTurn(sessionId: string, options: TurnValidationOptions): PreTurnValidation;

  /**
   * Clear all messages from context.
   * Unlike compaction, no summary is preserved - messages are just cleared.
   * @param sessionId - Session ID
   * @returns Clear result with token counts and cleared todos
   */
  clearContext(sessionId: string): Promise<ClearContextResult>;
}

// =============================================================================
// Service Options Types
// =============================================================================

export interface CompactionOptions {
  /** User-edited summary to use instead of generated one */
  editedSummary?: string;
  /** Reason for compaction (manual, auto, etc.) */
  reason?: string;
}

export interface TurnValidationOptions {
  /** Estimated tokens for the response */
  estimatedResponseTokens: number;
}

export interface ClearContextResult {
  /** Whether the operation succeeded */
  success: boolean;
  /** Token count before clearing */
  tokensBefore: number;
  /** Token count after clearing */
  tokensAfter: number;
  /** Todos that were cleared (for backlogging) */
  clearedTodos: Array<{
    id: string;
    content: string;
    status: string;
    source: string;
  }>;
}

// =============================================================================
// Service Dependencies
// =============================================================================

/**
 * Dependencies required by ContextService.
 */
export type ContextServiceDeps = ContextOpsConfig;

// =============================================================================
// Service Implementation
// =============================================================================

/**
 * ContextService implementation wrapping ContextOps.
 */
class ContextServiceImpl implements ContextService {
  private ops: ContextOps;

  constructor(deps: ContextServiceDeps) {
    this.ops = createContextOps(deps);
  }

  getSnapshot(sessionId: string): ContextSnapshot {
    return this.ops.getContextSnapshot(sessionId);
  }

  getDetailedSnapshot(sessionId: string): DetailedContextSnapshot {
    return this.ops.getDetailedContextSnapshot(sessionId);
  }

  shouldCompact(sessionId: string): boolean {
    return this.ops.shouldCompact(sessionId);
  }

  async previewCompaction(sessionId: string): Promise<CompactionPreview> {
    return this.ops.previewCompaction(sessionId);
  }

  async confirmCompaction(sessionId: string, options?: CompactionOptions): Promise<CompactionResult> {
    return this.ops.confirmCompaction(sessionId, options);
  }

  canAcceptTurn(sessionId: string, options: TurnValidationOptions): PreTurnValidation {
    return this.ops.canAcceptTurn(sessionId, options);
  }

  async clearContext(sessionId: string): Promise<ClearContextResult> {
    return this.ops.clearContext(sessionId);
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a new ContextService instance.
 * @param deps - Service dependencies
 * @returns ContextService instance
 */
export function createContextService(deps: ContextServiceDeps): ContextService {
  return new ContextServiceImpl(deps);
}

// =============================================================================
// Re-exports
// =============================================================================

export type {
  ContextSnapshot,
  DetailedContextSnapshot,
  PreTurnValidation,
  CompactionPreview,
  CompactionResult,
} from '../../context/types.js';
