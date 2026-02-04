/**
 * @fileoverview AgentController
 *
 * Manages agent execution for sessions. Handles running agents, auto-resume of
 * inactive sessions, processing state management, and cancellation.
 *
 * Part of Phase 4 of EventStoreOrchestrator refactoring.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type { RunResult } from '../../agent/types.js';
import type { AgentRunner } from '../agent-runner.js';
import type { ActiveSession, AgentRunOptions } from '../types.js';

const logger = createLogger('agent-controller');

// =============================================================================
// Types
// =============================================================================

export interface AgentControllerConfig {
  /** AgentRunner for actual execution coordination */
  agentRunner: AgentRunner;
  /** Get an active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Resume an inactive session */
  resumeSession: (sessionId: string) => Promise<unknown>;
}

// =============================================================================
// AgentController
// =============================================================================

/**
 * Controller for agent execution operations.
 *
 * Provides a clean interface for:
 * - Running agents with auto-resume of inactive sessions
 * - Cancelling running agents
 */
export class AgentController {
  private readonly agentRunner: AgentRunner;
  private readonly getActiveSession: (sessionId: string) => ActiveSession | undefined;
  private readonly resumeSession: (sessionId: string) => Promise<unknown>;

  constructor(config: AgentControllerConfig) {
    this.agentRunner = config.agentRunner;
    this.getActiveSession = config.getActiveSession;
    this.resumeSession = config.resumeSession;
  }

  /**
   * Run an agent on a session.
   * Auto-resumes inactive sessions.
   */
  async run(options: AgentRunOptions): Promise<RunResult[]> {
    let active = this.getActiveSession(options.sessionId);

    // Auto-resume session if not active (handles app reopen, server restart, etc.)
    if (!active) {
      logger.info('[AGENT] Auto-resuming inactive session', { sessionId: options.sessionId });
      try {
        await this.resumeSession(options.sessionId);
        active = this.getActiveSession(options.sessionId);
      } catch (err) {
        // Session doesn't exist or can't be resumed
        throw new Error(`Session not found: ${options.sessionId}`);
      }
      if (!active) {
        throw new Error(`Failed to resume session: ${options.sessionId}`);
      }
    }

    // Check processing state
    if (active.sessionContext.isProcessing()) {
      throw new Error('Session is already processing');
    }

    // Update processing state
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(true);

    // Set currentRunId for event correlation (event handlers access this from active session)
    active.currentRunId = options.runId;

    try {
      // Delegate to AgentRunner for all execution logic
      // AgentRunner handles: context injection, content building, agent execution,
      // interrupt handling, completion handling, error handling, and event emission
      return await this.agentRunner.run(active, options);
    } finally {
      // Clear processing state and runId
      active.sessionContext.setProcessing(false);
      active.currentRunId = undefined;
    }
  }

  /**
   * Cancel a running agent.
   * Returns true if agent was cancelled, false if session not found or not processing.
   */
  async cancel(sessionId: string): Promise<boolean> {
    const active = this.getActiveSession(sessionId);
    if (!active) {
      return false;
    }

    if (!active.sessionContext.isProcessing()) {
      return false;
    }

    // Actually abort the agent - triggers AbortController and interrupts execution
    active.agent.abort();

    // Clear processing state
    active.lastActivity = new Date();
    active.sessionContext.setProcessing(false);
    logger.info('Agent cancelled', { sessionId });
    return true;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an AgentController instance.
 */
export function createAgentController(config: AgentControllerConfig): AgentController {
  return new AgentController(config);
}
