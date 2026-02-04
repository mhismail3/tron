/**
 * @fileoverview Unified Spawn Subagent Tool
 *
 * Spawns a sub-agent in either in-process or tmux mode.
 * - inProcess: Runs in the same process, can block until complete
 * - tmux: Runs in a separate tmux session, always fire-and-forget
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import type { SubAgentTracker } from './subagent-tracker.js';
import type { ToolDenialConfig } from './tool-denial.js';
import type { SessionId } from '@infrastructure/events/types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:spawn-subagent');

/**
 * Parameters for spawning an agent
 */
export interface SpawnSubagentParams {
  /** The task/prompt for the agent to execute */
  task: string;
  /** Execution mode: 'inProcess' (default) or 'tmux' */
  mode?: 'inProcess' | 'tmux';
  /** Override model for the agent */
  model?: string;
  /**
   * Custom system prompt for the subagent.
   * If not specified, uses the default Tron system prompt.
   */
  systemPrompt?: string;
  /**
   * Tool denial configuration for this subagent.
   * Subagent inherits all parent tools minus any specified denials.
   *
   * @example
   * // Deny all tools (text generation only)
   * { denyAll: true }
   *
   * @example
   * // Deny specific tools
   * { tools: ['Bash', 'Write', 'SpawnSubagent'] }
   *
   * @example
   * // Granular denial with parameter patterns
   * {
   *   rules: [{
   *     tool: 'Bash',
   *     denyPatterns: [{ parameter: 'command', patterns: ['rm\\s+-rf', 'sudo'] }]
   *   }]
   * }
   */
  toolDenials?: ToolDenialConfig;
  /** Skills to load for the agent */
  skills?: string[];
  /** Working directory (defaults to parent session's directory) */
  workingDirectory?: string;
  /** Maximum turns allowed (default: 50 for inProcess, 100 for tmux) */
  maxTurns?: number;
  /**
   * Whether to block until the agent completes (inProcess mode only).
   * Default: true (blocking mode - waits for completion and returns full result)
   * Set to false for fire-and-forget mode where you'll use QueryAgent/WaitForAgents later.
   * Ignored in tmux mode (always fire-and-forget).
   */
  blocking?: boolean;
  /**
   * Maximum time to wait for agent completion in milliseconds (inProcess mode only).
   * Only applies when blocking=true. Default: 1800000 (30 minutes)
   */
  timeout?: number;
  /**
   * Custom tmux session name (tmux mode only).
   * Auto-generated if not provided.
   */
  sessionName?: string;
  /**
   * Hard timeout for subagent execution to prevent runaway (guardrail).
   * Default: 3600000 (1 hour). This is separate from the blocking timeout.
   * The subagent will be aborted if it runs longer than this.
   */
  guardrailTimeout?: number;
}

/**
 * Result of spawning an agent
 */
export interface SpawnSubagentResult {
  /** Session ID of the spawned agent */
  sessionId: string;
  /** Whether the operation was successful */
  success: boolean;
  /** Error message if spawn or execution failed */
  error?: string;
  /** Tmux session name (tmux mode only) */
  tmuxSessionName?: string;
  // === Fields populated when mode=inProcess, blocking=true, and agent completes ===
  /** Full output text from the agent (blocking inProcess mode only) */
  output?: string;
  /** Brief summary of the result (blocking inProcess mode only) */
  summary?: string;
  /** Total turns taken by the agent (blocking inProcess mode only) */
  totalTurns?: number;
  /** Duration in milliseconds (blocking inProcess mode only) */
  duration?: number;
  /** Token usage (blocking inProcess mode only) */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
  /** Whether the blocking wait was interrupted (blocking inProcess mode only) */
  interrupted?: boolean;
}

/**
 * Callback to spawn an agent (provided by orchestrator)
 */
export type SpawnSubagentCallback = (
  parentSessionId: string,
  params: SpawnSubagentParams,
  /** Tool call ID for correlating events with the tool call message */
  toolCallId: string
) => Promise<SpawnSubagentResult>;

/**
 * Configuration for SpawnSubagentTool
 */
export interface SpawnSubagentToolConfig {
  /** Current session ID (parent session) */
  sessionId: string;
  /** Default working directory */
  workingDirectory: string;
  /** Default model */
  model: string;
  /** Path to shared SQLite database (for tmux mode) */
  dbPath: string;
  /** Callback to spawn the agent */
  onSpawn: SpawnSubagentCallback;
  /**
   * Get the SubAgentTracker for blocking mode.
   * Required for waiting on agent completion in inProcess mode.
   */
  getSubagentTracker: () => SubAgentTracker;
}

/**
 * Unified tool for spawning agents in either inProcess or tmux mode
 */
export class SpawnSubagentTool implements TronTool<SpawnSubagentParams> {
  readonly name = 'SpawnSubagent';
  readonly description = `Spawn an agent to handle a specific task. Supports two execution modes:

**1. In-Process Mode (default):**
- Runs in the same process, sharing the event store
- **Blocking by default**: Waits for completion and returns full results
- Efficient for quick tasks (< 5 minutes)
- Use \`blocking: false\` for fire-and-forget

**2. Tmux Mode:**
- Runs in a separate tmux session with its own process
- Always fire-and-forget (returns immediately)
- Persists beyond this conversation
- Best for long-running tasks (hours/days)
- Can manually attach via \`tmux attach -t <session-name>\`

Parameters:
- **task**: The task description for the agent (required)
- **mode**: 'inProcess' (default) or 'tmux'
- **blocking**: If true (default), waits for completion (inProcess only)
- **timeout**: Max wait time in ms (default: 30 minutes, inProcess only)
- **sessionName**: Custom tmux session name (tmux only)
- **model**, **systemPrompt**, **toolDenials**, **skills**, **workingDirectory**, **maxTurns**: Optional overrides
- **toolDenials**: Deny tools/patterns. Use { denyAll: true } for text-only agents

Returns (when mode=inProcess and blocking=true):
- Full output from the agent
- Token usage and duration statistics
- Success/failure status`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      task: {
        type: 'string' as const,
        description: 'The task/prompt for the agent to execute. Be specific and provide all necessary context.',
      },
      mode: {
        type: 'string' as const,
        enum: ['inProcess', 'tmux'],
        description: 'Execution mode. "inProcess" (default) runs in the same process. "tmux" runs in a separate tmux session.',
      },
      model: {
        type: 'string' as const,
        description: 'Override the model for the agent. If not specified, uses the parent session\'s model.',
      },
      systemPrompt: {
        type: 'string' as const,
        description: 'Custom system prompt for the subagent. If not specified, uses the default Tron prompt.',
      },
      toolDenials: {
        type: 'object' as const,
        description: 'Tool denial configuration. Use { denyAll: true } for text-only agents, or { tools: ["Bash", "Write"] } to deny specific tools.',
        properties: {
          denyAll: { type: 'boolean' as const, description: 'Deny all tools (text generation only)' },
          tools: { type: 'array' as const, items: { type: 'string' as const }, description: 'Tools to deny by name' },
        },
      },
      skills: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Skills to load for the agent.',
      },
      workingDirectory: {
        type: 'string' as const,
        description: 'Working directory for the agent. Defaults to parent session\'s directory.',
      },
      maxTurns: {
        type: 'number' as const,
        description: 'Maximum turns allowed for the agent. Default: 50 (inProcess) or 100 (tmux).',
      },
      blocking: {
        type: 'boolean' as const,
        description: 'Whether to wait for agent completion (inProcess mode only). Default: true (blocks until done).',
      },
      timeout: {
        type: 'number' as const,
        description: 'Max wait time in ms when blocking (inProcess mode only). Default: 1800000 (30 minutes).',
      },
      sessionName: {
        type: 'string' as const,
        description: 'Custom tmux session name (tmux mode only). Auto-generated if not provided.',
      },
    },
    required: ['task'] as string[],
  };

  readonly category = 'custom' as const;
  readonly label = 'Spawn Sub-Agent';

  private config: SpawnSubagentToolConfig;

  constructor(config: SpawnSubagentToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallIdOrArgs: string | Record<string, unknown>,
    argsOrSignal?: Record<string, unknown> | AbortSignal,
    signalArg?: AbortSignal
  ): Promise<TronToolResult<SpawnSubagentResult>> {
    // Handle both old and new signatures
    let args: Record<string, unknown>;
    let toolCallId: string;
    let signal: AbortSignal | undefined;

    if (typeof toolCallIdOrArgs === 'string') {
      // New signature: (toolCallId, params, signal)
      toolCallId = toolCallIdOrArgs;
      args = argsOrSignal as Record<string, unknown>;
      signal = signalArg;
    } else {
      // Old signature: (params) - generate a fallback ID
      toolCallId = `spawn_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      args = toolCallIdOrArgs;
      // argsOrSignal could be an AbortSignal in old signature
      if (argsOrSignal instanceof AbortSignal) {
        signal = argsOrSignal;
      }
    }

    const task = args.task as string;
    const mode = (args.mode as 'inProcess' | 'tmux') ?? 'inProcess';
    const model = args.model as string | undefined;
    const systemPrompt = args.systemPrompt as string | undefined;
    const toolDenials = args.toolDenials as ToolDenialConfig | undefined;
    const skills = args.skills as string[] | undefined;
    const workingDirectory = args.workingDirectory as string | undefined;
    const maxTurns = args.maxTurns as number | undefined;
    const sessionName = args.sessionName as string | undefined;
    // Default to blocking mode for inProcess, ignored for tmux
    const isBlocking = mode === 'inProcess' && args.blocking !== false;
    // Default 30 minute timeout
    const timeout = (args.timeout as number | undefined) ?? 30 * 60 * 1000;

    // Validate required parameter
    if (!task || typeof task !== 'string' || task.trim() === '') {
      return {
        content: 'Error: Missing required parameter "task". Provide a clear task description for the agent.',
        isError: true,
        details: { success: false, sessionId: '', error: 'Missing task parameter' },
      };
    }

    logger.info('Spawning agent', {
      parentSessionId: this.config.sessionId,
      task: task.slice(0, 100),
      mode,
      model,
      maxTurns,
      blocking: isBlocking,
    });

    try {
      // Build spawn params
      const spawnParams: SpawnSubagentParams = {
        task,
        mode,
        model: model ?? this.config.model,
        systemPrompt,
        toolDenials,
        skills,
        workingDirectory: workingDirectory ?? this.config.workingDirectory,
        maxTurns: maxTurns ?? (mode === 'tmux' ? 100 : 50),
        sessionName,
      };

      // Spawn the agent (starts async execution)
      const spawnResult = await this.config.onSpawn(
        this.config.sessionId,
        spawnParams,
        toolCallId
      );

      if (!spawnResult.success) {
        logger.error('Failed to spawn agent', {
          parentSessionId: this.config.sessionId,
          mode,
          error: spawnResult.error,
        });

        return {
          content: `Failed to spawn agent: ${spawnResult.error ?? 'Unknown error'}`,
          isError: true,
          details: spawnResult,
        };
      }

      logger.info('Agent spawned successfully', {
        parentSessionId: this.config.sessionId,
        agentSessionId: spawnResult.sessionId,
        mode,
        blocking: isBlocking,
      });

      // TMUX MODE: Always fire-and-forget
      if (mode === 'tmux') {
        return {
          content: `Tmux agent spawned successfully.
**Session ID**: ${spawnResult.sessionId}
**Tmux Session**: ${spawnResult.tmuxSessionName}
**Type**: tmux (out-of-process)
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The agent is running in a separate tmux session. You can:
- Monitor via: QueryAgent({ sessionId: "${spawnResult.sessionId}", queryType: "status" })
- Attach manually: \`tmux attach -t ${spawnResult.tmuxSessionName}\`

The agent will continue running even if this session ends.`,
          isError: false,
          details: spawnResult,
        };
      }

      // IN-PROCESS MODE: Non-blocking
      if (!isBlocking) {
        return {
          content: `Agent spawned successfully.
**Session ID**: ${spawnResult.sessionId}
**Type**: in-process
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

You are responsible for monitoring this agent. Use QueryAgent to check its status and retrieve results when complete.

Example: QueryAgent({ sessionId: "${spawnResult.sessionId}", queryType: "status" })`,
          isError: false,
          details: spawnResult,
        };
      }

      // IN-PROCESS MODE: Blocking - wait for completion
      const tracker = this.config.getSubagentTracker();

      // Check if already aborted before waiting
      if (signal?.aborted) {
        logger.info('Agent wait aborted before start (signal already aborted)', {
          parentSessionId: this.config.sessionId,
          agentSessionId: spawnResult.sessionId,
        });

        return {
          content: `Agent execution was interrupted.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The subagent may still be running. Use QueryAgent to check status.`,
          isError: false,
          details: {
            sessionId: spawnResult.sessionId,
            success: false,
            interrupted: true,
          },
        };
      }

      try {
        // Race the wait against the abort signal
        let completionResult;
        if (signal) {
          // Create a promise that rejects when abort signal fires
          const abortPromise = new Promise<never>((_, reject) => {
            const abortHandler = () => reject(new Error('Aborted'));
            signal.addEventListener('abort', abortHandler, { once: true });
          });

          completionResult = await Promise.race([
            tracker.waitFor(spawnResult.sessionId as SessionId, timeout),
            abortPromise,
          ]);
        } else {
          completionResult = await tracker.waitFor(
            spawnResult.sessionId as SessionId,
            timeout
          );
        }

        // Build the full result
        const fullResult: SpawnSubagentResult = {
          sessionId: spawnResult.sessionId,
          success: completionResult.success,
          output: completionResult.output,
          summary: completionResult.summary,
          totalTurns: completionResult.totalTurns,
          duration: completionResult.duration,
          tokenUsage: completionResult.tokenUsage,
          error: completionResult.error,
        };

        const durationSec = (completionResult.duration / 1000).toFixed(1);
        const statusIcon = completionResult.success ? '✅' : '❌';

        if (completionResult.success) {
          logger.info('Agent completed successfully', {
            parentSessionId: this.config.sessionId,
            agentSessionId: spawnResult.sessionId,
            turns: completionResult.totalTurns,
            duration: completionResult.duration,
          });

          return {
            content: `${statusIcon} Agent completed successfully.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}
**Turns**: ${completionResult.totalTurns}
**Duration**: ${durationSec}s
**Tokens**: ${completionResult.tokenUsage.inputTokens.toLocaleString()} in / ${completionResult.tokenUsage.outputTokens.toLocaleString()} out

**Output**:
${completionResult.output}`,
            isError: false,
            details: fullResult,
          };
        } else {
          logger.warn('Agent failed', {
            parentSessionId: this.config.sessionId,
            agentSessionId: spawnResult.sessionId,
            error: completionResult.error,
          });

          return {
            content: `${statusIcon} Agent failed.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}
**Turns**: ${completionResult.totalTurns}
**Duration**: ${durationSec}s
**Error**: ${completionResult.error}`,
            isError: false, // Not a tool error - agent execution failed
            details: fullResult,
          };
        }
      } catch (waitError) {
        const err = waitError as Error;

        // Handle abort signal
        if (err.message === 'Aborted') {
          logger.info('Agent wait aborted by parent session', {
            parentSessionId: this.config.sessionId,
            agentSessionId: spawnResult.sessionId,
          });

          return {
            content: `Agent execution was interrupted.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The subagent may still be running. Use QueryAgent to check status.`,
            isError: false,
            details: {
              sessionId: spawnResult.sessionId,
              success: false,
              interrupted: true,
            },
          };
        }

        // Timeout or other wait error
        logger.error('Agent timed out or wait failed', {
          parentSessionId: this.config.sessionId,
          agentSessionId: spawnResult.sessionId,
          error: err.message,
          timeout,
        });

        return {
          content: `Agent timed out after ${(timeout / 1000).toFixed(0)}s.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The agent is still running. Use QueryAgent to check its status later, or WaitForAgents to wait longer.`,
          isError: true,
          details: {
            sessionId: spawnResult.sessionId,
            success: false,
            error: `Timed out after ${timeout}ms`,
          },
        };
      }
    } catch (error) {
      const err = error as Error;
      logger.error('Error spawning agent', {
        parentSessionId: this.config.sessionId,
        mode,
        error: err.message,
      });

      return {
        content: `Error spawning agent: ${err.message}`,
        isError: true,
        details: { success: false, sessionId: '', error: err.message },
      };
    }
  }
}
