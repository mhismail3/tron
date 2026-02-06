/**
 * @fileoverview Sub-Agent Spawn Handler
 *
 * Handles spawning sub-agents both in-process (subsessions) and
 * out-of-process (tmux).
 */
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '@infrastructure/logging/index.js';
import type { EventStore } from '@infrastructure/events/index.js';
import type { SessionId, EventType } from '@infrastructure/events/index.js';
import type { SpawnSubagentParams, SubagentCompletionType } from '@capabilities/tools/subagent/index.js';
import { spawn as spawnProcess } from 'child_process';
import type {
  ActiveSession,
  AgentRunOptions,
  SessionInfo,
  CreateSessionOptions,
} from '../../types.js';
import type { SpawnSubagentResult, SpawnTmuxAgentResult } from './types.js';
import type { RunResult } from '../../../agent/types.js';

const logger = createLogger('subagent-spawn');

// =============================================================================
// Types
// =============================================================================

/**
 * Default guardrail timeout for subagent execution (1 hour)
 */
const DEFAULT_GUARDRAIL_TIMEOUT_MS = 60 * 60 * 1000;
const TMUX_STARTUP_TIMEOUT_MS = 10_000;
const TMUX_SESSION_NAME_PATTERN = /^[A-Za-z0-9._:-]{1,80}$/;

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
  /** Run agent for a session - returns RunResult[] */
  runAgent: (options: AgentRunOptions) => Promise<RunResult[]>;
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
    params: SpawnSubagentParams,
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
        // Pass custom system prompt if provided
        systemPrompt: params.systemPrompt,
        // Pass tool denials if provided (undefined = all tools, { denyAll: true } = no tools)
        toolDenials: params.toolDenials,
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
          systemPrompt: params.systemPrompt,
          toolDenials: params.toolDenials,
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

      // Run sub-agent asynchronously with guardrail timeout
      // Note: The .catch() is a fallback for truly unexpected errors that escape the try-finally
      this.runSubagentAsync(
        subSession.sessionId,
        parentSessionId,
        params.task,
        params.maxTurns ?? 50,
        params.guardrailTimeout ?? DEFAULT_GUARDRAIL_TIMEOUT_MS,
        toolCallId
      ).catch((error) => {
        const structured = categorizeError(error, { parentSessionId, subagentSessionId: subSession.sessionId, operation: 'subagent_execution' });
        logger.error('Subagent execution failed (escaped try-finally)', {
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
        blocking: params.blocking ?? false,
      });

      // If blocking mode, wait for the subagent to complete
      if (params.blocking) {
        const timeout = params.timeout ?? 5 * 60 * 1000; // Default 5 minutes
        try {
          logger.debug('Waiting for blocking subagent to complete', {
            subagentSessionId: subSession.sessionId,
            timeout,
          });

          const result = await parent.subagentTracker.waitFor(
            subSession.sessionId as SessionId,
            timeout
          );

          logger.info('Blocking subagent completed', {
            subagentSessionId: subSession.sessionId,
            success: result.success,
            outputLength: result.output?.length ?? 0,
          });

          return {
            sessionId: subSession.sessionId,
            success: result.success,
            output: result.output,
            resultSummary: result.summary,
            tokenUsage: result.tokenUsage,
            error: result.error,
          };
        } catch (waitError) {
          const err = waitError as Error;
          logger.error('Blocking subagent wait failed', {
            subagentSessionId: subSession.sessionId,
            error: err.message,
          });
          return {
            sessionId: subSession.sessionId,
            success: false,
            error: `Subagent wait failed: ${err.message}`,
          };
        }
      }

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
    params: SpawnSubagentParams
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
      const tmuxSessionName = this.resolveTmuxSessionName(
        params.sessionName,
        timestamp
      );

      // Generate a session ID for the sub-agent (will be created by the spawned process)
      const subSessionId = `sess_${timestamp}${Math.random().toString(36).slice(2, 8)}`;
      const maxTurns = this.resolveMaxTurns(params.maxTurns);

      // Build tron command args as a tokenized vector. This avoids shell command
      // string construction and prevents argument-injection via quoting tricks.
      const workDir = params.workingDirectory ?? parent.workingDirectory;
      const dbPath = this.deps.eventStore.getDbPath();
      this.validateTmuxSpawnInputs(params.task, workDir, dbPath);

      const tronArgs = [
        '--parent-session-id',
        parentSessionId,
        '--spawn-task',
        params.task,
        '--db-path',
        dbPath,
        '--working-directory',
        workDir,
        '--max-turns',
        String(maxTurns),
      ];

      if (params.model) {
        tronArgs.push('--model', params.model);
      }

      // Start tmux session and verify startup before reporting success.
      const startResult = await this.runCommand(
        'tmux',
        [
          'new-session',
          '-d',
          '-s',
          tmuxSessionName,
          '-c',
          workDir,
          '--',
          'tron',
          ...tronArgs,
        ],
        {
          detached: false,
          stdio: ['ignore', 'ignore', 'pipe'],
        }
      );

      if (startResult.exitCode !== 0) {
        throw new Error(
          startResult.stderr ||
            `tmux new-session failed with exit code ${startResult.exitCode ?? 'unknown'}`
        );
      }

      const verifyResult = await this.runCommand(
        'tmux',
        ['has-session', '-t', tmuxSessionName],
        {
          detached: false,
          stdio: ['ignore', 'ignore', 'pipe'],
        }
      );

      if (verifyResult.exitCode !== 0) {
        throw new Error(
          verifyResult.stderr ||
            `tmux session startup verification failed for ${tmuxSessionName}`
        );
      }

      // Emit subagent.spawned event in parent session
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.spawned' as EventType,
        {
          subagentSessionId: subSessionId,
          spawnType: 'tmux',
          task: params.task,
          model: params.model ?? parent.model,
          toolDenials: params.toolDenials,
          skills: params.skills,
          workingDirectory: workDir,
          tmuxSessionName,
          maxTurns,
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
        { tmuxSessionName, maxTurns }
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
   *
   * GUARANTEED: This method ALWAYS delivers a result to the tracker,
   * either via complete() or fail(). The try-finally pattern ensures
   * no code path can exit without delivering a result.
   */
  private async runSubagentAsync(
    sessionId: string,
    parentSessionId: string,
    task: string,
    _maxTurns: number,
    guardrailTimeoutMs: number = DEFAULT_GUARDRAIL_TIMEOUT_MS,
    toolCallId?: string
  ): Promise<void> {
    const startTime = Date.now();
    let resultDelivered = false;
    let guardrailTimedOut = false;

    // Set up guardrail timeout to prevent runaway subagents
    const abortController = new AbortController();
    const guardrailTimer = setTimeout(() => {
      guardrailTimedOut = true;
      abortController.abort();
      logger.warn('Subagent guardrail timeout triggered', {
        sessionId,
        parentSessionId,
        timeoutMs: guardrailTimeoutMs,
      });
    }, guardrailTimeoutMs);

    try {
      const parent = this.deps.getActiveSession(parentSessionId);

      // Update status to running
      if (parent) {
        parent.subagentTracker.updateStatus(sessionId as SessionId, 'running');
      }

      // Run the agent with the task
      // Note: Streaming events (tool_start, text_delta, etc.) are forwarded to parent
      // automatically by AgentEventHandler.forwardToParent() based on parentSessionId
      const runResults = await this.deps.runAgent({
        sessionId,
        prompt: task,
        signal: abortController.signal,
      });

      // Extract stopReason from run result
      const runResult = runResults?.[0];
      const stopReason = runResult?.stoppedReason;

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

      // Detect problem scenarios and determine completion type
      const { resultSummary, completionType, truncated, warning } = this.analyzeCompletion(
        fullOutput,
        stopReason,
        session?.turnCount ?? 0
      );

      const tokenUsage = {
        inputTokens: session?.totalInputTokens ?? 0,
        outputTokens: session?.totalOutputTokens ?? 0,
      };

      // Get model from tracked subagent (available from spawn event)
      const trackedSubagent = parent?.subagentTracker.get(sessionId as SessionId);
      const model = trackedSubagent?.model;

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
          model,
          stopReason,
          truncated,
          completionType,
          warning,
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
          model,
          stopReason,
          truncated,
          completionType,
          warning,
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
          fullOutput,
          { stopReason, truncated, completionType }
        );
        resultDelivered = true;

        // Emit notification for explicitly invoked subagents (has a toolCallId).
        // Background subagents (LedgerWriter, LLMSummarizer) don't have toolCallIds.
        // We emit regardless of parent processing state — fast subagents may complete
        // before the parent finishes its turn, and the iOS client handles display timing.
        if (toolCallId) {
          const notificationData = {
            parentSessionId,
            subagentSessionId: sessionId,
            task: currentParent.subagentTracker.get(sessionId as SessionId)?.task ?? '',
            resultSummary,
            success: true,
            totalTurns: session?.turnCount ?? 0,
            duration,
            tokenUsage,
            completedAt: new Date().toISOString(),
            warning,
          };

          // Persist the notification event for reconstruction
          this.deps.appendEventLinearized(
            parentSessionId as SessionId,
            'notification.subagent_result' as EventType,
            notificationData
          );

          // Emit WebSocket event for live clients
          this.deps.emit('agent_event', {
            type: 'agent.subagent_result_available',
            sessionId: parentSessionId,
            timestamp: new Date().toISOString(),
            data: notificationData,
          });

          logger.info('Subagent completed while parent idle, notification emitted and persisted', {
            parentSessionId,
            subagentSessionId: sessionId,
          });
        }
      }

      logger.info('Subagent completed', {
        parentSessionId,
        subagentSessionId: sessionId,
        turns: session?.turnCount,
        duration,
        outputLength: fullOutput.length,
        stopReason,
        completionType,
        truncated,
        hasWarning: !!warning,
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
            completionType,
            truncated,
            warning,
          },
        },
      });
    } catch (error) {
      const duration = Date.now() - startTime;

      // Determine if this was a guardrail timeout
      const completionType: SubagentCompletionType = guardrailTimedOut ? 'timeout' : 'error';
      const errorMessage = guardrailTimedOut
        ? `Subagent guardrail timeout exceeded (${guardrailTimeoutMs}ms)`
        : (error instanceof Error ? error.message : String(error));

      const structured = categorizeError(error, { parentSessionId, subagentSessionId: sessionId, operation: 'run_subagent' });

      // Emit failure event
      this.deps.appendEventLinearized(
        parentSessionId as SessionId,
        'subagent.failed' as EventType,
        {
          subagentSessionId: sessionId,
          error: errorMessage,
          recoverable: false,
          duration,
          completionType,
        }
      );

      // Emit WebSocket event for iOS real-time updates
      this.deps.emit('agent_event', {
        type: 'agent.subagent_failed',
        sessionId: parentSessionId,
        timestamp: new Date().toISOString(),
        data: {
          subagentSessionId: sessionId,
          error: errorMessage,
          duration,
          completionType,
        },
      });

      // Update tracker
      // Re-fetch parent since time has passed
      const currentParent = this.deps.getActiveSession(parentSessionId);
      if (currentParent) {
        currentParent.subagentTracker.fail(sessionId as SessionId, errorMessage, {
          duration,
          completionType,
        });
        resultDelivered = true;

        // Emit notification for explicitly invoked subagents only (has toolCallId).
        // Background subagents should not show result chips to the user.
        if (toolCallId) {
          const notificationData = {
            parentSessionId,
            subagentSessionId: sessionId,
            task: currentParent.subagentTracker.get(sessionId as SessionId)?.task ?? '',
            resultSummary: '',
            success: false,
            totalTurns: 0,
            duration,
            error: errorMessage,
            completedAt: new Date().toISOString(),
            completionType,
          };

          // Persist the notification event for reconstruction
          this.deps.appendEventLinearized(
            parentSessionId as SessionId,
            'notification.subagent_result' as EventType,
            notificationData
          );

          // Emit WebSocket event for live clients
          this.deps.emit('agent_event', {
            type: 'agent.subagent_result_available',
            sessionId: parentSessionId,
            timestamp: new Date().toISOString(),
            data: notificationData,
          });

          logger.info('Subagent failed while parent idle, notification emitted and persisted', {
            parentSessionId,
            subagentSessionId: sessionId,
          });
        }
      }

      logger.error('Subagent failed', {
        parentSessionId,
        subagentSessionId: sessionId,
        code: LogErrorCodes.SUB_ERROR,
        category: LogErrorCategory.SUBAGENT,
        error: structured.message,
        retryable: structured.retryable,
        duration,
        completionType,
        guardrailTimedOut,
      });

      // Emit SubagentStop hook
      this.deps.emit('hook', {
        type: 'SubagentStop',
        sessionId: parentSessionId,
        data: {
          subagentId: sessionId,
          stopReason: completionType,
          result: { success: false, error: errorMessage, completionType },
        },
      });
    } finally {
      // Clear the guardrail timer
      clearTimeout(guardrailTimer);

      // GUARANTEED RESULT DELIVERY: If no result was delivered by try or catch,
      // deliver a failure result now. This should never happen, but ensures
      // the tracker always gets a result.
      if (!resultDelivered) {
        const duration = Date.now() - startTime;
        const currentParent = this.deps.getActiveSession(parentSessionId);

        if (currentParent && !currentParent.subagentTracker.isTerminated(sessionId as SessionId)) {
          const errorMessage = 'Subagent terminated without delivering result (unexpected code path)';

          currentParent.subagentTracker.fail(
            sessionId as SessionId,
            errorMessage,
            { duration, completionType: 'error' }
          );

          // Emit failure event for this edge case
          this.deps.appendEventLinearized(
            parentSessionId as SessionId,
            'subagent.failed' as EventType,
            {
              subagentSessionId: sessionId,
              error: errorMessage,
              recoverable: false,
              duration,
              completionType: 'error',
            }
          );

          logger.error('Subagent fell through without result (safety net triggered)', {
            parentSessionId,
            subagentSessionId: sessionId,
            duration,
          });
        }
      }
    }
  }

  /**
   * Analyze subagent completion and determine result metadata.
   * Detects max_tokens, empty output, and generates appropriate warnings.
   */
  private analyzeCompletion(
    fullOutput: string,
    stopReason: string | undefined,
    turnCount: number
  ): {
    resultSummary: string;
    completionType: SubagentCompletionType;
    truncated: boolean;
    warning: string | undefined;
  } {
    let warning: string | undefined;
    let completionType: SubagentCompletionType = 'success';
    const truncated = stopReason === 'max_tokens';

    // Detect max_tokens truncation
    if (truncated) {
      completionType = 'max_tokens';
      warning = 'Output was truncated due to token limit. The response may be incomplete.';
    }

    // Detect empty output
    if (!fullOutput || fullOutput.trim().length === 0) {
      if (truncated) {
        warning = 'Hit token limit before producing any text output. Consider increasing maxTokens or breaking the task into smaller chunks.';
      } else {
        warning = 'Subagent completed without producing text output.';
      }
    }

    // Build result summary
    let resultSummary: string;
    if (warning) {
      const outputPreview = fullOutput?.slice(0, 150) || 'No output';
      resultSummary = `[WARNING: ${warning}] ${outputPreview}${fullOutput && fullOutput.length > 150 ? '...' : ''}`;
    } else if (fullOutput) {
      resultSummary = fullOutput.length > 200
        ? fullOutput.slice(0, 200) + '...'
        : fullOutput;
    } else {
      resultSummary = `Completed task in ${turnCount} turns`;
    }

    return { resultSummary, completionType, truncated, warning };
  }

  private resolveTmuxSessionName(sessionName: string | undefined, timestamp: string): string {
    const rawName = (sessionName ?? `tron-subagent-${timestamp}`).trim();
    if (!TMUX_SESSION_NAME_PATTERN.test(rawName)) {
      throw new Error(
        'Invalid tmux session name. Use only letters, numbers, ".", "_", ":" or "-".'
      );
    }
    return rawName;
  }

  private resolveMaxTurns(maxTurns: number | undefined): number {
    const value = maxTurns ?? 100;
    if (!Number.isInteger(value) || value <= 0 || value > 10_000) {
      throw new Error('maxTurns must be an integer between 1 and 10000');
    }
    return value;
  }

  private validateTmuxSpawnInputs(task: string, workDir: string, dbPath: string): void {
    if (!task || typeof task !== 'string' || task.trim().length === 0) {
      throw new Error('Subagent task is required');
    }
    if (!workDir || workDir.includes('\u0000')) {
      throw new Error('Invalid working directory');
    }
    if (!dbPath || dbPath.includes('\u0000')) {
      throw new Error('Invalid database path');
    }
  }

  private runCommand(
    command: string,
    args: string[],
    options: Parameters<typeof spawnProcess>[2]
  ): Promise<{ exitCode: number | null; stderr: string }> {
    return new Promise((resolve, reject) => {
      const proc = spawnProcess(command, args, options);
      let stderr = '';
      const timeout = setTimeout(() => {
        proc.kill();
        reject(new Error(`${command} timed out after ${TMUX_STARTUP_TIMEOUT_MS}ms`));
      }, TMUX_STARTUP_TIMEOUT_MS);

      proc.stderr?.on('data', (chunk) => {
        stderr += chunk.toString();
      });

      proc.on('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });

      proc.on('close', (exitCode) => {
        clearTimeout(timeout);
        resolve({ exitCode, stderr: stderr.trim() });
      });
    });
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
