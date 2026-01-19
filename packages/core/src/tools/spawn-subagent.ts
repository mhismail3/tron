/**
 * @fileoverview Spawn Subagent Tool
 *
 * Spawns an in-process sub-agent using EventStoreOrchestrator.
 * The sub-agent runs asynchronously and can be monitored via QuerySubagent.
 */

import type { TronTool, TronToolResult } from '../types/index.js';
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
}

/**
 * Result of spawning a sub-agent
 */
export interface SpawnSubagentResult {
  /** Session ID of the spawned sub-agent */
  sessionId: string;
  /** Whether spawn was successful */
  success: boolean;
  /** Error message if spawn failed */
  error?: string;
}

/**
 * Callback to spawn a sub-agent (provided by orchestrator)
 */
export type SpawnSubagentCallback = (
  parentSessionId: string,
  params: SpawnSubagentParams
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
}

/**
 * Tool for spawning in-process sub-agents
 */
export class SpawnSubagentTool implements TronTool<SpawnSubagentParams> {
  readonly name = 'SpawnSubagent';
  readonly description = `Spawn an in-process sub-agent to handle a specific task. The sub-agent runs asynchronously and can be monitored using QuerySubagent. Use this for tasks that can be delegated to a focused sub-agent while you continue with other work.

The sub-agent:
- Has its own session and context
- Can use the same tools as the parent session
- Runs in the same process, sharing the event store
- Reports status via events that you can query

Best used for:
- Independent, well-defined tasks
- Tasks that benefit from focused context
- Parallel work where you don't need immediate results`;

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

    if (typeof toolCallIdOrArgs === 'string') {
      // New signature: (toolCallId, params, signal)
      args = argsOrSignal as Record<string, unknown>;
    } else {
      // Old signature: (params)
      args = toolCallIdOrArgs;
    }

    const task = args.task as string;
    const model = args.model as string | undefined;
    const tools = args.tools as string[] | undefined;
    const skills = args.skills as string[] | undefined;
    const workingDirectory = args.workingDirectory as string | undefined;
    const maxTurns = args.maxTurns as number | undefined;

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
    });

    try {
      const result = await this.config.onSpawn(this.config.sessionId, {
        task,
        model: model ?? this.config.model,
        tools,
        skills,
        workingDirectory: workingDirectory ?? this.config.workingDirectory,
        maxTurns: maxTurns ?? 50,
      });

      if (!result.success) {
        logger.error('Failed to spawn sub-agent', {
          parentSessionId: this.config.sessionId,
          error: result.error,
        });

        return {
          content: `Failed to spawn sub-agent: ${result.error ?? 'Unknown error'}`,
          isError: true,
          details: result,
        };
      }

      logger.info('Sub-agent spawned successfully', {
        parentSessionId: this.config.sessionId,
        subagentSessionId: result.sessionId,
      });

      return {
        content: `Sub-agent spawned successfully.
**Session ID**: ${result.sessionId}
**Type**: subagent (in-process)
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

You are responsible for monitoring this sub-agent. Use QuerySubagent to check its status and retrieve results when complete.

Example: QuerySubagent({ sessionId: "${result.sessionId}", queryType: "status" })`,
        isError: false,
        details: result,
      };
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
