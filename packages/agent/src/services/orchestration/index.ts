/**
 * @fileoverview Orchestration Service
 *
 * Provides agent run coordination with a clean interface.
 * This is primarily an interface definition - the actual implementation
 * lives in EventStoreOrchestrator which implements this interface.
 *
 * ## Responsibilities
 * - Agent run coordination
 * - Turn lifecycle management
 * - Processing state management
 *
 * ## Usage
 * ```typescript
 * // The EventStoreOrchestrator implements OrchestrationService
 * const orchestrator = new EventStoreOrchestrator(config);
 * await orchestrator.runAgent({ sessionId: 'session-123', prompt: 'Help me' });
 * ```
 */
import type { RunResult } from '../../agent/types.js';
import type { AgentRunOptions } from '../../orchestrator/types.js';

// =============================================================================
// Service Interface
// =============================================================================

/**
 * Orchestration service interface - clean contract for agent run coordination.
 *
 * This interface is implemented by EventStoreOrchestrator to provide
 * a clear contract for agent execution.
 */
export interface OrchestrationService {
  /**
   * Run an agent turn for a session.
   * Handles the full lifecycle including skill loading, message recording,
   * agent execution, and event persistence.
   * @param options - Run options including sessionId and prompt
   * @returns Array of run results (typically single element)
   */
  runAgent(options: AgentRunOptions): Promise<RunResult[]>;

  /**
   * Cancel an active agent run.
   * @param sessionId - Session ID to cancel
   * @returns True if cancellation was successful
   */
  cancelAgent(sessionId: string): Promise<boolean>;

  /**
   * Check if a session is currently processing.
   * @param sessionId - Session ID to check
   * @returns True if session is processing an agent turn
   */
  isProcessing(sessionId: string): boolean;
}

// =============================================================================
// Re-exports
// =============================================================================

export type { AgentRunOptions, AgentEvent } from '../../orchestrator/types.js';
export type { RunResult } from '../../agent/types.js';
