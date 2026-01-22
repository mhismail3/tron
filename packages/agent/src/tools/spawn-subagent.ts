/**
 * @fileoverview Spawn Subagent Tool
 *
 * Spawns an in-process sub-agent using EventStoreOrchestrator.
 * The sub-agent runs asynchronously and can be monitored via QuerySubagent.
 */

import type { TronTool, TronToolResult } from '../types/index.js';
import type { SubAgentTracker } from './subagent-tracker.js';
import type { SessionId } from '../events/types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:spawn-subagent');

/**
 * Parameters for spawning a sub-agent
 */
export interface SpawnSubagentParams {
  /** The task/prompt for the sub-agent to execute */
  task: string;
  /** Override model for the sub-agent */
  model?: string;
  /** Specific tools to enable (if not specified, uses default tools) */
  tools?: string[];
  /** Skills to load for the sub-agent */
  skills?: string[];
  /** Working directory (defaults to parent session's directory) */
  workingDirectory?: string;
  /** Maximum turns allowed (default: 50) */
  maxTurns?: number;
  /**
   * Whether to block until the subagent completes.
   * Default: true (blocking mode - waits for completion and returns full result)
   * Set to false for fire-and-forget mode where you'll use QuerySubagent/WaitForSubagent later.
   */
  blocking?: boolean;
  /**
   * Maximum time to wait for subagent completion in milliseconds.
   * Only applies when blocking=true. Default: 1800000 (30 minutes)
   */
  timeout?: number;
}

/**
 * Result of spawning a sub-agent
 */
export interface SpawnSubagentResult {
  /** Session ID of the spawned sub-agent */
  sessionId: string;
  /** Whether the operation was successful */
  success: boolean;
  /** Error message if spawn or execution failed */
  error?: string;
  // === Fields populated when blocking=true and subagent completes ===
  /** Full output text from the subagent (blocking mode only) */
  output?: string;
  /** Brief summary of the result (blocking mode only) */
  summary?: string;
  /** Total turns taken by the subagent (blocking mode only) */
  totalTurns?: number;
  /** Duration in milliseconds (blocking mode only) */
  duration?: number;
  /** Token usage (blocking mode only) */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

/**
 * Callback to spawn a sub-agent (provided by orchestrator)
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
  /** Callback to spawn the sub-agent */
  onSpawn: SpawnSubagentCallback;
  /**
   * Get the SubAgentTracker for blocking mode.
   * Required for waiting on subagent completion.
   */
  getSubagentTracker: () => SubAgentTracker;
}

/**
 * Tool for spawning in-process sub-agents
 */
export class SpawnSubagentTool implements TronTool<SpawnSubagentParams> {
  readonly name = 'SpawnSubagent';
  readonly description = `Spawn an in-process sub-agent to handle a specific task.

By default, this tool **blocks** until the sub-agent completes, then returns the full result including output, token usage, and duration. This makes it easy to delegate a task and immediately use the result.

The sub-agent:
- Has its own session and context
- Can use the same tools as the parent session
- Runs in the same process, sharing the event store
- Returns full results when complete (blocking mode)

Parameters:
- **task**: The task description for the sub-agent (required)
- **blocking**: If true (default), waits for completion. If false, returns immediately.
- **timeout**: Max wait time in ms (default: 30 minutes)
- **model**, **tools**, **skills**, **workingDirectory**, **maxTurns**: Optional overrides

Returns (when blocking):
- Full output from the sub-agent
- Token usage and duration statistics
- Success/failure status`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      task: {
        type: 'string' as const,
        description: 'The task/prompt for the sub-agent to execute. Be specific and provide all necessary context.',
      },
      model: {
        type: 'string' as const,
        description: 'Override the model for the sub-agent. If not specified, uses the parent session\'s model.',
      },
      tools: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Specific tools to enable for the sub-agent. If not specified, uses default tools.',
      },
      skills: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Skills to load for the sub-agent.',
      },
      workingDirectory: {
        type: 'string' as const,
        description: 'Working directory for the sub-agent. Defaults to parent session\'s directory.',
      },
      maxTurns: {
        type: 'number' as const,
        description: 'Maximum turns allowed for the sub-agent. Default: 50.',
      },
      blocking: {
        type: 'boolean' as const,
        description: 'Whether to wait for subagent completion. Default: true (blocks until done).',
      },
      timeout: {
        type: 'number' as const,
        description: 'Max wait time in ms when blocking. Default: 1800000 (30 minutes).',
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
    _signal?: AbortSignal
  ): Promise<TronToolResult<SpawnSubagentResult>> {
    // Handle both old and new signatures
    let args: Record<string, unknown>;
    let toolCallId: string;

    if (typeof toolCallIdOrArgs === 'string') {
      // New signature: (toolCallId, params, signal)
      toolCallId = toolCallIdOrArgs;
      args = argsOrSignal as Record<string, unknown>;
    } else {
      // Old signature: (params) - generate a fallback ID
      toolCallId = `spawn_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      args = toolCallIdOrArgs;
    }

    const task = args.task as string;
    const model = args.model as string | undefined;
    const tools = args.tools as string[] | undefined;
    const skills = args.skills as string[] | undefined;
    const workingDirectory = args.workingDirectory as string | undefined;
    const maxTurns = args.maxTurns as number | undefined;
    // Default to blocking mode
    const isBlocking = args.blocking !== false;
    // Default 30 minute timeout
    const timeout = (args.timeout as number | undefined) ?? 30 * 60 * 1000;

    // Validate required parameter
    if (!task || typeof task !== 'string') {
      return {
        content: 'Error: Missing required parameter "task". Provide a clear task description for the sub-agent.',
        isError: true,
        details: { success: false, sessionId: '', error: 'Missing task parameter' },
      };
    }

    logger.info('Spawning sub-agent', {
      parentSessionId: this.config.sessionId,
      task: task.slice(0, 100),
      model,
      maxTurns,
      blocking: isBlocking,
    });

    try {
      // Spawn the subagent (starts async execution)
      const spawnResult = await this.config.onSpawn(
        this.config.sessionId,
        {
          task,
          model: model ?? this.config.model,
          tools,
          skills,
          workingDirectory: workingDirectory ?? this.config.workingDirectory,
          maxTurns: maxTurns ?? 50,
        },
        toolCallId
      );

      if (!spawnResult.success) {
        logger.error('Failed to spawn sub-agent', {
          parentSessionId: this.config.sessionId,
          error: spawnResult.error,
        });

        return {
          content: `Failed to spawn sub-agent: ${spawnResult.error ?? 'Unknown error'}`,
          isError: true,
          details: spawnResult,
        };
      }

      logger.info('Sub-agent spawned successfully', {
        parentSessionId: this.config.sessionId,
        subagentSessionId: spawnResult.sessionId,
        blocking: isBlocking,
      });

      // NON-BLOCKING MODE: Return immediately
      if (!isBlocking) {
        return {
          content: `Sub-agent spawned successfully.
**Session ID**: ${spawnResult.sessionId}
**Type**: subagent (in-process)
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

You are responsible for monitoring this sub-agent. Use QuerySubagent to check its status and retrieve results when complete.

Example: QuerySubagent({ sessionId: "${spawnResult.sessionId}", queryType: "status" })`,
          isError: false,
          details: spawnResult,
        };
      }

      // BLOCKING MODE: Wait for completion
      const tracker = this.config.getSubagentTracker();

      try {
        const completionResult = await tracker.waitFor(
          spawnResult.sessionId as SessionId,
          timeout
        );

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
          logger.info('Sub-agent completed successfully', {
            parentSessionId: this.config.sessionId,
            subagentSessionId: spawnResult.sessionId,
            turns: completionResult.totalTurns,
            duration: completionResult.duration,
          });

          return {
            content: `${statusIcon} Sub-agent completed successfully.
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
          logger.warn('Sub-agent failed', {
            parentSessionId: this.config.sessionId,
            subagentSessionId: spawnResult.sessionId,
            error: completionResult.error,
          });

          return {
            content: `${statusIcon} Sub-agent failed.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}
**Turns**: ${completionResult.totalTurns}
**Duration**: ${durationSec}s
**Error**: ${completionResult.error}`,
            isError: false, // Not a tool error - subagent execution failed
            details: fullResult,
          };
        }
      } catch (waitError) {
        // Timeout or other wait error
        const err = waitError as Error;
        logger.error('Sub-agent timed out or wait failed', {
          parentSessionId: this.config.sessionId,
          subagentSessionId: spawnResult.sessionId,
          error: err.message,
          timeout,
        });

        return {
          content: `Sub-agent timed out after ${(timeout / 1000).toFixed(0)}s.
**Session ID**: ${spawnResult.sessionId}
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The sub-agent is still running. Use QuerySubagent to check its status later, or WaitForSubagent to wait longer.`,
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
      logger.error('Error spawning sub-agent', {
        parentSessionId: this.config.sessionId,
        error: err.message,
      });

      return {
        content: `Error spawning sub-agent: ${err.message}`,
        isError: true,
        details: { success: false, sessionId: '', error: err.message },
      };
    }
  }
}
