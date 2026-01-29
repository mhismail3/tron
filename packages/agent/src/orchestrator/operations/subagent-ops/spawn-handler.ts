/**
 * @fileoverview Sub-Agent Spawn Handler
 *
 * Handles spawning sub-agents both in-process (subsessions) and
 * out-of-process (tmux).
 */
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '../../../logging/index.js';
import type { EventStore } from '../../../events/index.js';
import type { SessionId, EventType } from '../../../events/index.js';
import type { SpawnAgentParams } from '../../../tools/subagent/index.js';
import type {
  ActiveSession,
  AgentRunOptions,
  SessionInfo,
  CreateSessionOptions,
} from '../../types.js';
import type { SpawnSubagentResult, SpawnTmuxAgentResult } from './types.js';

const logger = createLogger('subagent-spawn');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for SpawnHandler
 */
export interface SpawnHandlerDeps {
  /** EventStore instance for querying sessions */
  eventStore: EventStore;
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Create a new session */
  createSession: (options: CreateSessionOptions) => Promise<SessionInfo>;
  /** Run agent for a session */
  runAgent: (options: AgentRunOptions) => Promise<unknown>;
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// SpawnHandler Class
// =============================================================================

/**
 * Handles spawning sub-agents both in-process and out-of-process.
 */
export class SpawnHandler {
  private deps: SpawnHandlerDeps;

  constructor(deps: SpawnHandlerDeps) {
    this.deps = deps;
  }

  /**
   * Spawn an in-process sub-agent session.
   * The sub-agent runs asynchronously and shares the event store.
   */
  async spawnSubsession(
    parentSessionId: string,
    params: SpawnAgentParams,
    toolCallId?: string
  ): Promise<SpawnSubagentResult> {
    const parent = this.deps.getActiveSession(parentSessionId);
    if (!parent) {
      return {
        sessionId: '',
        success: false,
        error: 'Parent session not found',
      };
    }

    try {
      // Create a new session for the sub-agent
      const subSession = await this.deps.createSession({
        workingDirectory: params.workingDirectory ?? parent.workingDirectory,
        model: params.model ?? parent.model,
        title: `Subagent: ${params.task.slice(0, 50)}`,
        tags: ['subagent', 'subsession'],
        // Pass parent session ID for event forwarding
        parentSessionId,
      });

      // Update the session in DB with spawning info
      this.deps.eventStore.updateSessionSpawnInfo(
        subSession.sessionId as SessionId,
        parentSessionId as SessionId,
        'subsession',
        params.task
      );

      // Emit subagent.spawned event in parent session
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.spawned' as EventType,
        {
          subagentSessionId: subSession.sessionId,
          spawnType: 'subsession',
          task: params.task,
          model: params.model ?? parent.model,
          tools: params.tools,
          skills: params.skills,
          workingDirectory: params.workingDirectory ?? parent.workingDirectory,
          maxTurns: params.maxTurns ?? 50,
        }
      );

      // Emit WebSocket event for iOS real-time updates
      this.deps.emit('agent_event', {
        type: 'agent.subagent_spawned',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: subSession.sessionId,
          toolCallId, // Include for iOS to match with tool call message
          task: params.task,
          model: params.model ?? parent.model,
          workingDirectory: params.workingDirectory ?? parent.workingDirectory,
        },
      });

      // Track in parent's subagent tracker
      parent.subagentTracker.spawn(
        subSession.sessionId as SessionId,
        'subsession',
        params.task,
        params.model ?? parent.model,
        params.workingDirectory ?? parent.workingDirectory,
        '', // Event ID will be set when event is created
        { maxTurns: params.maxTurns ?? 50 }
      );

      // Run sub-agent asynchronously
      this.runSubagentAsync(
        subSession.sessionId,
        parentSessionId,
        params.task,
        params.maxTurns ?? 50
      ).catch((error) => {
        const structured = categorizeError(error, { parentSessionId, subagentSessionId: subSession.sessionId, operation: 'subagent_execution' });
        logger.error('Subagent execution failed', {
          parentSessionId,
          subagentSessionId: subSession.sessionId,
          code: structured.code,
          category: LogErrorCategory.SUBAGENT,
          error: structured.message,
          retryable: structured.retryable,
        });
      });

      logger.info('Subsession spawned', {
        parentSessionId,
        subagentSessionId: subSession.sessionId,
        task: params.task.slice(0, 100),
      });

      return { sessionId: subSession.sessionId, success: true };
    } catch (error) {
      const structured = categorizeError(error, { parentSessionId, operation: 'spawn_subsession' });
      logger.error('Failed to spawn subsession', {
        parentSessionId,
        code: LogErrorCodes.SUB_SPAWN,
        category: LogErrorCategory.SUBAGENT,
        error: structured.message,
        retryable: structured.retryable,
      });
      return { sessionId: '', success: false, error: structured.message };
    }
  }

  /**
   * Spawn an out-of-process sub-agent in a tmux session.
   * The sub-agent runs independently with its own process.
   */
  async spawnTmuxAgent(
    parentSessionId: string,
    params: SpawnAgentParams
  ): Promise<SpawnTmuxAgentResult> {
    const parent = this.deps.getActiveSession(parentSessionId);
    if (!parent) {
      return {
        sessionId: '',
        tmuxSessionName: '',
        success: false,
        error: 'Parent session not found',
      };
    }

    try {
      // Generate tmux session name
      const timestamp = Date.now().toString(36);
      const tmuxSessionName =
        params.sessionName ?? `tron-subagent-${timestamp}`;

      // Generate a session ID for the sub-agent (will be created by the spawned process)
      const subSessionId = `sess_${timestamp}${Math.random().toString(36).slice(2, 8)}`;

      // Build the tron command with spawn flags
      const workDir = params.workingDirectory ?? parent.workingDirectory;
      const tronCmd = [
        'tron',
        `--parent-session-id=${parentSessionId}`,
        `--spawn-task="${params.task.replace(/"/g, '\\"')}"`,
        `--db-path="${this.deps.eventStore.getDbPath()}"`,
        `--working-directory="${workDir}"`,
        params.model ? `--model=${params.model}` : '',
        `--max-turns=${params.maxTurns ?? 100}`,
      ]
        .filter(Boolean)
        .join(' ');

      // Spawn tmux session
      const { spawn } = await import('child_process');
      const tmuxProc = spawn(
        'tmux',
        ['new-session', '-d', '-s', tmuxSessionName, '-c', workDir, tronCmd],
        {
          detached: true,
          stdio: 'ignore',
        }
      );
      tmuxProc.unref();

      // Emit subagent.spawned event in parent session
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.spawned' as EventType,
        {
          subagentSessionId: subSessionId,
          spawnType: 'tmux',
          task: params.task,
          model: params.model ?? parent.model,
          tools: params.tools,
          skills: params.skills,
          workingDirectory: workDir,
          tmuxSessionName,
          maxTurns: params.maxTurns ?? 100,
        }
      );

      // Track in parent's subagent tracker
      parent.subagentTracker.spawn(
        subSessionId as SessionId,
        'tmux',
        params.task,
        params.model ?? parent.model,
        workDir,
        '',
        { tmuxSessionName, maxTurns: params.maxTurns ?? 100 }
      );

      logger.info('Tmux agent spawned', {
        parentSessionId,
        subagentSessionId: subSessionId,
        tmuxSessionName,
        task: params.task.slice(0, 100),
      });

      return { sessionId: subSessionId, tmuxSessionName, success: true };
    } catch (error) {
      const structured = categorizeError(error, { parentSessionId, operation: 'spawn_tmux_agent' });
      logger.error('Failed to spawn tmux agent', {
        parentSessionId,
        code: LogErrorCodes.SUB_SPAWN,
        category: LogErrorCategory.SUBAGENT,
        error: structured.message,
        retryable: structured.retryable,
      });
      return {
        sessionId: '',
        tmuxSessionName: '',
        success: false,
        error: structured.message,
      };
    }
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  /**
   * Run a sub-agent asynchronously (for in-process subsessions).
   */
  private async runSubagentAsync(
    sessionId: string,
    parentSessionId: string,
    task: string,
    _maxTurns: number
  ): Promise<void> {
    const startTime = Date.now();
    const parent = this.deps.getActiveSession(parentSessionId);

    try {
      // Update status to running
      if (parent) {
        parent.subagentTracker.updateStatus(sessionId as SessionId, 'running');
      }

      // Run the agent with the task
      // Note: Streaming events (tool_start, text_delta, etc.) are forwarded to parent
      // automatically by AgentEventHandler.forwardToParent() based on parentSessionId
      await this.deps.runAgent({
        sessionId,
        prompt: task,
      });

      // Get final stats
      const session = await this.deps.eventStore.getSession(
        sessionId as SessionId
      );
      const duration = Date.now() - startTime;

      // Get full output from the last assistant message
      let fullOutput = '';
      if (session?.headEventId) {
        const allEvents = await this.deps.eventStore.getAncestors(
          session.headEventId
        );
        const lastAssistantMsg = allEvents
          .filter((e) => e.type === 'message.assistant')
          .reverse()
          .find((e) => e.type === 'message.assistant');

        if (lastAssistantMsg) {
          const payload = lastAssistantMsg.payload as {
            content: Array<{ type: string; text?: string }>;
          };
          fullOutput =
            payload.content
              ?.filter((b: { type: string }) => b.type === 'text')
              .map((b: { text?: string }) => b.text)
              .join('\n') ?? '';
        }
      }

      const resultSummary = fullOutput
        ? fullOutput.length > 200
          ? fullOutput.slice(0, 200) + '...'
          : fullOutput
        : `Completed task in ${session?.turnCount ?? 0} turns`;

      const tokenUsage = {
        inputTokens: session?.totalInputTokens ?? 0,
        outputTokens: session?.totalOutputTokens ?? 0,
      };

      // Emit completion event with full output
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.completed' as EventType,
        {
          subagentSessionId: sessionId,
          resultSummary,
          fullOutput,
          totalTurns: session?.turnCount ?? 0,
          totalTokenUsage: tokenUsage,
          duration,
        }
      );

      // Emit WebSocket event for iOS real-time updates
      this.deps.emit('agent_event', {
        type: 'agent.subagent_completed',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: sessionId,
          resultSummary,
          fullOutput,
          totalTurns: session?.turnCount ?? 0,
          duration,
          tokenUsage,
        },
      });

      // Update tracker (this triggers waiting promises and callbacks)
      // Re-fetch parent since time has passed
      const currentParent = this.deps.getActiveSession(parentSessionId);
      if (currentParent) {
        currentParent.subagentTracker.complete(
          sessionId as SessionId,
          resultSummary,
          session?.turnCount ?? 0,
          tokenUsage,
          duration,
          fullOutput
        );
      }

      logger.info('Subagent completed', {
        parentSessionId,
        subagentSessionId: sessionId,
        turns: session?.turnCount,
        duration,
        outputLength: fullOutput.length,
      });

      // Emit SubagentStop hook with full result
      this.deps.emit('hook', {
        type: 'SubagentStop',
        sessionId: parentSessionId,
        data: {
          subagentId: sessionId,
          stopReason: 'completed',
          result: {
            success: true,
            turns: session?.turnCount ?? 0,
            output: fullOutput,
            tokenUsage,
            duration,
          },
        },
      });
    } catch (error) {
      const structured = categorizeError(error, { parentSessionId, subagentSessionId: sessionId, operation: 'run_subagent' });
      const duration = Date.now() - startTime;

      // Emit failure event
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.failed' as EventType,
        {
          subagentSessionId: sessionId,
          error: structured.message,
          recoverable: false,
          duration,
        }
      );

      // Emit WebSocket event for iOS real-time updates
      this.deps.emit('agent_event', {
        type: 'agent.subagent_failed',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: sessionId,
          error: structured.message,
          duration,
        },
      });

      // Update tracker
      // Re-fetch parent since time has passed
      const currentParent = this.deps.getActiveSession(parentSessionId);
      if (currentParent) {
        currentParent.subagentTracker.fail(sessionId as SessionId, structured.message, {
          duration,
        });
      }

      logger.error('Subagent failed', {
        parentSessionId,
        subagentSessionId: sessionId,
        code: LogErrorCodes.SUB_ERROR,
        category: LogErrorCategory.SUBAGENT,
        error: structured.message,
        retryable: structured.retryable,
        duration,
      });

      // Emit SubagentStop hook
      this.deps.emit('hook', {
        type: 'SubagentStop',
        sessionId: parentSessionId,
        data: {
          subagentId: sessionId,
          stopReason: 'error',
          result: { success: false, error: structured.message },
        },
      });
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a SpawnHandler instance
 */
export function createSpawnHandler(deps: SpawnHandlerDeps): SpawnHandler {
  return new SpawnHandler(deps);
}
