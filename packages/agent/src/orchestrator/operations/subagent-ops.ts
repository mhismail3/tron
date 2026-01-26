/**
 * @fileoverview Sub-Agent Operations
 *
 * Extracted from EventStoreOrchestrator as part of modular refactoring.
 * Handles all sub-agent spawning, querying, and waiting operations.
 *
 * ## Operations
 *
 * - **spawnSubsession**: Spawn an in-process sub-agent
 * - **spawnTmuxAgent**: Spawn an out-of-process sub-agent in tmux
 * - **querySubagent**: Query sub-agent status, events, logs, or output
 * - **waitForSubagents**: Wait for sub-agent(s) to complete
 * - **buildSubagentResultsContext**: Format pending results for injection
 *
 * ## Design
 *
 * - Stateless module that operates on provided dependencies
 * - Uses callbacks for orchestrator operations (session creation, agent run)
 * - All event persistence via provided appendEvent callback
 * - SubAgentTracker managed by ActiveSession, accessed via callbacks
 */
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '../../logging/logger.js';
import type { EventStore } from '../../events/event-store.js';
import type {
  SessionId,
  EventType,
  SessionEvent as TronSessionEvent,
} from '../../events/types.js';
import type { SpawnSubagentParams } from '../../tools/subagent/spawn-subagent.js';
import type { SpawnTmuxAgentParams } from '../../tools/subagent/spawn-tmux-agent.js';
import type {
  SubagentQueryType,
  SubagentStatusInfo,
  SubagentEventInfo,
  SubagentLogInfo,
} from '../../tools/subagent/query-subagent.js';
import type { SubagentResult } from '../../tools/subagent/subagent-tracker.js';
import type { ActiveSession, AgentRunOptions, SessionInfo, CreateSessionOptions } from '../types.js';

const logger = createLogger('subagent-ops');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for SubagentOperations
 */
export interface SubagentOperationsConfig {
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

/**
 * Result of spawning a subsession
 */
export interface SpawnSubagentResult {
  sessionId: string;
  success: boolean;
  error?: string;
}

/**
 * Result of spawning a tmux agent
 */
export interface SpawnTmuxAgentResult {
  sessionId: string;
  tmuxSessionName: string;
  success: boolean;
  error?: string;
}

/**
 * Result of querying a sub-agent
 */
export interface QuerySubagentResult {
  success: boolean;
  status?: SubagentStatusInfo;
  events?: SubagentEventInfo[];
  logs?: SubagentLogInfo[];
  output?: string;
  error?: string;
}

/**
 * Result of waiting for sub-agents
 */
export interface WaitForSubagentsResult {
  success: boolean;
  results?: SubagentResult[];
  error?: string;
  timedOut?: boolean;
}

// =============================================================================
// SubagentOperations Class
// =============================================================================

/**
 * Handles all sub-agent operations for the orchestrator.
 * Stateless module that uses callbacks for orchestrator integration.
 */
export class SubagentOperations {
  private config: SubagentOperationsConfig;

  constructor(config: SubagentOperationsConfig) {
    this.config = config;
  }

  // ===========================================================================
  // Public Methods
  // ===========================================================================

  /**
   * Spawn an in-process sub-agent session.
   * The sub-agent runs asynchronously and shares the event store.
   */
  async spawnSubsession(
    parentSessionId: string,
    params: SpawnSubagentParams,
    toolCallId?: string
  ): Promise<SpawnSubagentResult> {
    const parent = this.config.getActiveSession(parentSessionId);
    if (!parent) {
      return { sessionId: '', success: false, error: 'Parent session not found' };
    }

    try {
      // Create a new session for the sub-agent
      const subSession = await this.config.createSession({
        workingDirectory: params.workingDirectory ?? parent.workingDirectory,
        model: params.model ?? parent.model,
        title: `Subagent: ${params.task.slice(0, 50)}`,
        tags: ['subagent', 'subsession'],
        // Pass parent session ID for event forwarding
        parentSessionId,
      });

      // Update the session in DB with spawning info
      this.config.eventStore.updateSessionSpawnInfo(
        subSession.sessionId as SessionId,
        parentSessionId as SessionId,
        'subsession',
        params.task
      );

      // Emit subagent.spawned event in parent session
      this.config.appendEventLinearized(
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
      this.config.emit('agent_event', {
        type: 'agent.subagent_spawned',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: subSession.sessionId,
          toolCallId,  // Include for iOS to match with tool call message
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
      ).catch(error => {
        logger.error('Subagent execution failed', {
          parentSessionId,
          subagentSessionId: subSession.sessionId,
          error: (error as Error).message,
        });
      });

      logger.info('Subsession spawned', {
        parentSessionId,
        subagentSessionId: subSession.sessionId,
        task: params.task.slice(0, 100),
      });

      return { sessionId: subSession.sessionId, success: true };
    } catch (error) {
      const err = error as Error;
      logger.error('Failed to spawn subsession', {
        parentSessionId,
        error: err.message,
      });
      return { sessionId: '', success: false, error: err.message };
    }
  }

  /**
   * Spawn an out-of-process sub-agent in a tmux session.
   * The sub-agent runs independently with its own process.
   */
  async spawnTmuxAgent(
    parentSessionId: string,
    params: SpawnTmuxAgentParams
  ): Promise<SpawnTmuxAgentResult> {
    const parent = this.config.getActiveSession(parentSessionId);
    if (!parent) {
      return { sessionId: '', tmuxSessionName: '', success: false, error: 'Parent session not found' };
    }

    try {
      // Generate tmux session name
      const timestamp = Date.now().toString(36);
      const tmuxSessionName = params.sessionName ?? `tron-subagent-${timestamp}`;

      // Generate a session ID for the sub-agent (will be created by the spawned process)
      const subSessionId = `sess_${timestamp}${Math.random().toString(36).slice(2, 8)}`;

      // Build the tron command with spawn flags
      const workDir = params.workingDirectory ?? parent.workingDirectory;
      const tronCmd = [
        'tron',
        `--parent-session-id=${parentSessionId}`,
        `--spawn-task="${params.task.replace(/"/g, '\\"')}"`,
        `--db-path="${this.config.eventStore.getDbPath()}"`,
        `--working-directory="${workDir}"`,
        params.model ? `--model=${params.model}` : '',
        `--max-turns=${params.maxTurns ?? 100}`,
      ].filter(Boolean).join(' ');

      // Spawn tmux session
      const { spawn } = await import('child_process');
      const tmuxProc = spawn('tmux', [
        'new-session',
        '-d',
        '-s', tmuxSessionName,
        '-c', workDir,
        tronCmd,
      ], {
        detached: true,
        stdio: 'ignore',
      });
      tmuxProc.unref();

      // Emit subagent.spawned event in parent session
      this.config.appendEventLinearized(
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
      const err = error as Error;
      logger.error('Failed to spawn tmux agent', {
        parentSessionId,
        error: err.message,
      });
      return { sessionId: '', tmuxSessionName: '', success: false, error: err.message };
    }
  }

  /**
   * Query a sub-agent's status, events, logs, or output.
   */
  async querySubagent(
    sessionId: string,
    queryType: SubagentQueryType,
    limit?: number
  ): Promise<QuerySubagentResult> {
    try {
      // Get session info from event store
      const session = await this.config.eventStore.getSession(sessionId as SessionId);
      if (!session) {
        return { success: false, error: 'Session not found' };
      }

      switch (queryType) {
        case 'status': {
          const isEnded = session.endedAt !== null;
          let status: 'running' | 'completed' | 'failed' | 'unknown' = 'unknown';
          if (this.config.getActiveSession(sessionId)) {
            status = 'running';
          } else if (isEnded) {
            // Check if there's a failure event
            const allEvents = session.headEventId
              ? await this.config.eventStore.getAncestors(session.headEventId)
              : [];
            // Take last 20 events to check for errors
            const events = allEvents.slice(-20);
            const hasFailed = events.some(e => e.type === 'error.agent');
            status = hasFailed ? 'failed' : 'completed';
          }

          return {
            success: true,
            status: {
              sessionId,
              status,
              spawnType: session.spawnType as 'subsession' | 'tmux' | 'fork' | null,
              task: session.spawnTask,
              turnCount: session.turnCount,
              inputTokens: session.totalInputTokens,
              outputTokens: session.totalOutputTokens,
              cost: session.totalCost,
              createdAt: session.createdAt,
              lastActivityAt: session.lastActivityAt,
              endedAt: session.endedAt,
              model: session.latestModel,
              workingDirectory: session.workingDirectory,
            },
          };
        }

        case 'events': {
          const allEvents = session.headEventId
            ? await this.config.eventStore.getAncestors(session.headEventId)
            : [];
          // Take last N events
          const events = allEvents.slice(-(limit ?? 20));

          return {
            success: true,
            events: events.reverse().map(e => ({
              id: e.id,
              type: e.type,
              timestamp: e.timestamp,
              summary: this.summarizeEvent(e),
            })),
          };
        }

        case 'logs': {
          // Query logs table for this session
          const logs = await this.config.eventStore.getLogsForSession(sessionId as SessionId, limit ?? 20);
          return {
            success: true,
            logs: logs.map((l: { timestamp: string; level: string; component: string; message: string }) => ({
              timestamp: l.timestamp,
              level: l.level,
              component: l.component,
              message: l.message,
            })),
          };
        }

        case 'output': {
          // Get the last assistant message from the session
          const allEvents = session.headEventId
            ? await this.config.eventStore.getAncestors(session.headEventId)
            : [];
          // Take last 50 events to find assistant message
          const events = allEvents.slice(-50);

          const lastAssistantMsg = events
            .reverse()
            .find(e => e.type === 'message.assistant');

          if (!lastAssistantMsg) {
            return { success: true, output: undefined };
          }

          // Extract text from content blocks
          const payload = lastAssistantMsg.payload as { content: Array<{ type: string; text?: string }> };
          const text = payload.content
            ?.filter((b: { type: string }) => b.type === 'text')
            .map((b: { text?: string }) => b.text)
            .join('\n');

          return { success: true, output: text };
        }

        default:
          return { success: false, error: `Unknown query type: ${queryType}` };
      }
    } catch (error) {
      const err = error as Error;
      logger.error('Failed to query subagent', { sessionId, queryType, error: err.message });
      return { success: false, error: err.message };
    }
  }

  // NOTE: waitForSubagents is NOT implemented here because it requires
  // iterating all active sessions to find the parent tracker. The orchestrator
  // implements this directly since it has access to activeSessions.

  /**
   * Build context string for pending sub-agent results.
   * Consumes the pending results after formatting them.
   */
  buildSubagentResultsContext(active: ActiveSession): string | undefined {
    if (!active.subagentTracker.hasPendingResults()) {
      return undefined;
    }

    // Consume pending results
    const results = active.subagentTracker.consumePendingResults();

    if (results.length === 0) {
      return undefined;
    }

    // Format results into context
    let context = '# Completed Sub-Agent Results\n\n';
    context += 'The following sub-agent(s) have completed since your last turn. ';
    context += 'Review their results and incorporate them into your response as appropriate.\n\n';

    for (const result of results) {
      const statusIcon = result.success ? '✅' : '❌';
      context += `## ${statusIcon} Sub-Agent: \`${result.sessionId}\`\n\n`;
      context += `**Task**: ${result.task}\n`;
      context += `**Status**: ${result.success ? 'Completed successfully' : 'Failed'}\n`;
      context += `**Turns**: ${result.totalTurns}\n`;
      context += `**Duration**: ${(result.duration / 1000).toFixed(1)}s\n`;

      if (result.error) {
        context += `**Error**: ${result.error}\n`;
      }

      if (result.output) {
        // Truncate very long outputs
        const maxOutputLength = 2000;
        const truncatedOutput = result.output.length > maxOutputLength
          ? result.output.slice(0, maxOutputLength) + '\n\n... [Output truncated. Use QuerySubagent for full output]'
          : result.output;
        context += `\n**Output**:\n\`\`\`\n${truncatedOutput}\n\`\`\`\n`;
      }

      context += '\n---\n\n';
    }

    return context;
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
    const parent = this.config.getActiveSession(parentSessionId);

    try {
      // Update status to running
      if (parent) {
        parent.subagentTracker.updateStatus(sessionId as SessionId, 'running');
      }

      // Run the agent with the task
      // Note: Streaming events (tool_start, text_delta, etc.) are forwarded to parent
      // automatically by AgentEventHandler.forwardToParent() based on parentSessionId
      await this.config.runAgent({
        sessionId,
        prompt: task,
      });

      // Get final stats
      const session = await this.config.eventStore.getSession(sessionId as SessionId);
      const duration = Date.now() - startTime;

      // Get full output from the last assistant message
      let fullOutput = '';
      if (session?.headEventId) {
        const allEvents = await this.config.eventStore.getAncestors(session.headEventId);
        const lastAssistantMsg = allEvents
          .filter(e => e.type === 'message.assistant')
          .reverse()
          .find(e => e.type === 'message.assistant');

        if (lastAssistantMsg) {
          const payload = lastAssistantMsg.payload as { content: Array<{ type: string; text?: string }> };
          fullOutput = payload.content
            ?.filter((b: { type: string }) => b.type === 'text')
            .map((b: { text?: string }) => b.text)
            .join('\n') ?? '';
        }
      }

      const resultSummary = fullOutput
        ? (fullOutput.length > 200 ? fullOutput.slice(0, 200) + '...' : fullOutput)
        : `Completed task in ${session?.turnCount ?? 0} turns`;

      const tokenUsage = {
        inputTokens: session?.totalInputTokens ?? 0,
        outputTokens: session?.totalOutputTokens ?? 0,
      };

      // Emit completion event with full output
      this.config.appendEventLinearized(
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
      this.config.emit('agent_event', {
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
      const currentParent = this.config.getActiveSession(parentSessionId);
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
      this.config.emit('hook', {
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
      const err = error as Error;
      const duration = Date.now() - startTime;

      // Emit failure event
      this.config.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.failed' as EventType,
        {
          subagentSessionId: sessionId,
          error: err.message,
          recoverable: false,
          duration,
        }
      );

      // Emit WebSocket event for iOS real-time updates
      this.config.emit('agent_event', {
        type: 'agent.subagent_failed',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: sessionId,
          error: err.message,
          duration,
        },
      });

      // Update tracker
      // Re-fetch parent since time has passed
      const currentParent = this.config.getActiveSession(parentSessionId);
      if (currentParent) {
        currentParent.subagentTracker.fail(sessionId as SessionId, err.message, { duration });
      }

      logger.error('Subagent failed', {
        parentSessionId,
        subagentSessionId: sessionId,
        error: err.message,
        duration,
      });

      // Emit SubagentStop hook
      this.config.emit('hook', {
        type: 'SubagentStop',
        sessionId: parentSessionId,
        data: {
          subagentId: sessionId,
          stopReason: 'error',
          result: { success: false, error: err.message },
        },
      });
    }
  }

  /**
   * Summarize an event for display.
   */
  private summarizeEvent(event: TronSessionEvent): string {
    const payload = event.payload as Record<string, unknown>;
    switch (event.type) {
      case 'message.user':
        return `User: ${String(payload.content ?? '').slice(0, 50)}...`;
      case 'message.assistant':
        return `Assistant response (turn ${payload.turn ?? '?'})`;
      case 'tool.call':
        return `Tool call: ${payload.name ?? 'unknown'}`;
      case 'tool.result':
        return `Tool result: ${payload.isError ? 'error' : 'success'}`;
      case 'session.start':
        return 'Session started';
      case 'session.end':
        return `Session ended: ${payload.reason ?? 'unknown'}`;
      default:
        return event.type;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a SubagentOperations instance
 */
export function createSubagentOperations(
  config: SubagentOperationsConfig
): SubagentOperations {
  return new SubagentOperations(config);
}
