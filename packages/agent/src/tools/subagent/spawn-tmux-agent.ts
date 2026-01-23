/**
 * @fileoverview Spawn Tmux Agent Tool
 *
 * Spawns an out-of-process sub-agent in a tmux session.
 * The sub-agent runs independently and shares the SQLite database for event logging.
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('tool:spawn-tmux-agent');

/**
 * Parameters for spawning a tmux agent
 */
export interface SpawnTmuxAgentParams {
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
  /** Custom tmux session name (auto-generated if not provided) */
  sessionName?: string;
  /** Maximum turns allowed (default: 100) */
  maxTurns?: number;
}

/**
 * Result of spawning a tmux agent
 */
export interface SpawnTmuxAgentResult {
  /** Session ID of the spawned sub-agent */
  sessionId: string;
  /** Tmux session name */
  tmuxSessionName: string;
  /** Whether spawn was successful */
  success: boolean;
  /** Error message if spawn failed */
  error?: string;
}

/**
 * Callback to spawn a tmux agent (provided by orchestrator)
 */
export type SpawnTmuxAgentCallback = (
  parentSessionId: string,
  params: SpawnTmuxAgentParams
) => Promise<SpawnTmuxAgentResult>;

/**
 * Configuration for SpawnTmuxAgentTool
 */
export interface SpawnTmuxAgentToolConfig {
  /** Current session ID (parent session) */
  sessionId: string;
  /** Default working directory */
  workingDirectory: string;
  /** Default model */
  model: string;
  /** Path to shared SQLite database */
  dbPath: string;
  /** Callback to spawn the tmux agent */
  onSpawn: SpawnTmuxAgentCallback;
}

/**
 * Tool for spawning out-of-process sub-agents in tmux sessions
 */
export class SpawnTmuxAgentTool implements TronTool<SpawnTmuxAgentParams> {
  readonly name = 'SpawnTmuxAgent';
  readonly description = `Spawn an out-of-process sub-agent in a tmux session. The sub-agent runs independently with its own process, sharing the event database with the parent session.

The sub-agent:
- Runs in a separate tmux session that persists beyond this conversation
- Can be attached to manually via \`tmux attach -t <session-name>\`
- Shares the SQLite event database for monitoring and result retrieval
- Has its own process memory and context
- Better for long-running tasks or tasks that may outlive this session

Best used for:
- Long-running tasks (hours/days)
- Tasks that need to continue if the parent session ends
- Heavyweight tasks that benefit from process isolation
- Tasks you want to manually observe via tmux attach`;

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
      sessionName: {
        type: 'string' as const,
        description: 'Custom tmux session name. If not provided, one is auto-generated based on the task.',
      },
      maxTurns: {
        type: 'number' as const,
        description: 'Maximum turns allowed for the sub-agent. Default: 100.',
      },
    },
    required: ['task'] as string[],
  };

  readonly category = 'custom' as const;
  readonly label = 'Spawn Tmux Agent';

  private config: SpawnTmuxAgentToolConfig;

  constructor(config: SpawnTmuxAgentToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallIdOrArgs: string | Record<string, unknown>,
    argsOrSignal?: Record<string, unknown> | AbortSignal,
    _signal?: AbortSignal
  ): Promise<TronToolResult<SpawnTmuxAgentResult>> {
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
    const sessionName = args.sessionName as string | undefined;
    const maxTurns = args.maxTurns as number | undefined;

    // Validate required parameter
    if (!task || typeof task !== 'string') {
      return {
        content: 'Error: Missing required parameter "task". Provide a clear task description for the sub-agent.',
        isError: true,
        details: { success: false, sessionId: '', tmuxSessionName: '', error: 'Missing task parameter' },
      };
    }

    logger.info('Spawning tmux agent', {
      parentSessionId: this.config.sessionId,
      task: task.slice(0, 100),
      model,
      sessionName,
      maxTurns,
    });

    try {
      const result = await this.config.onSpawn(this.config.sessionId, {
        task,
        model: model ?? this.config.model,
        tools,
        skills,
        workingDirectory: workingDirectory ?? this.config.workingDirectory,
        sessionName,
        maxTurns: maxTurns ?? 100,
      });

      if (!result.success) {
        logger.error('Failed to spawn tmux agent', {
          parentSessionId: this.config.sessionId,
          error: result.error,
        });

        return {
          content: `Failed to spawn tmux agent: ${result.error ?? 'Unknown error'}`,
          isError: true,
          details: result,
        };
      }

      logger.info('Tmux agent spawned successfully', {
        parentSessionId: this.config.sessionId,
        subagentSessionId: result.sessionId,
        tmuxSessionName: result.tmuxSessionName,
      });

      return {
        content: `Tmux agent spawned successfully.
**Session ID**: ${result.sessionId}
**Tmux Session**: ${result.tmuxSessionName}
**Type**: tmux (out-of-process)
**Task**: ${task.slice(0, 200)}${task.length > 200 ? '...' : ''}

The sub-agent is running in a separate tmux session. You can:
- Monitor via: QuerySubagent({ sessionId: "${result.sessionId}", queryType: "status" })
- Attach manually: \`tmux attach -t ${result.tmuxSessionName}\`

The sub-agent will continue running even if this session ends.`,
        isError: false,
        details: result,
      };
    } catch (error) {
      const err = error as Error;
      logger.error('Error spawning tmux agent', {
        parentSessionId: this.config.sessionId,
        error: err.message,
      });

      return {
        content: `Error spawning tmux agent: ${err.message}`,
        isError: true,
        details: { success: false, sessionId: '', tmuxSessionName: '', error: err.message },
      };
    }
  }
}
