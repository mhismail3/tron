/**
 * @fileoverview Query Subagent Tool
 *
 * Query the status, events, logs, or output of a spawned sub-agent.
 */

import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:query-subagent');

/**
 * Query type for subagent queries
 */
export type SubagentQueryType = 'status' | 'events' | 'logs' | 'output';

/**
 * Parameters for querying a subagent
 */
export interface QuerySubagentParams {
  /** Session ID of the sub-agent to query */
  sessionId: string;
  /** Type of query to perform */
  queryType: SubagentQueryType;
  /** Limit number of results (for events/logs) */
  limit?: number;
}

/**
 * Status information for a sub-agent
 */
export interface SubagentStatusInfo {
  /** Session ID */
  sessionId: string;
  /** Current status */
  status: 'running' | 'completed' | 'failed' | 'unknown';
  /** Spawn type */
  spawnType: 'subsession' | 'tmux' | 'fork' | null;
  /** Task given to the sub-agent */
  task: string | null;
  /** Current turn count */
  turnCount: number;
  /** Token usage */
  inputTokens: number;
  outputTokens: number;
  /** Cost so far */
  cost: number;
  /** Created time */
  createdAt: string;
  /** Last activity time */
  lastActivityAt: string;
  /** End time if completed/failed */
  endedAt: string | null;
  /** Model used */
  model: string;
  /** Working directory */
  workingDirectory: string;
  /** Tmux session name if applicable */
  tmuxSessionName?: string;
}

/**
 * Event from a sub-agent session
 */
export interface SubagentEventInfo {
  id: string;
  type: string;
  timestamp: string;
  summary: string;
}

/**
 * Log entry from a sub-agent session
 */
export interface SubagentLogInfo {
  timestamp: string;
  level: string;
  component: string;
  message: string;
}

/**
 * Result of a subagent query
 */
export interface QuerySubagentResult {
  /** Whether query was successful */
  success: boolean;
  /** Status info (for status query) */
  status?: SubagentStatusInfo;
  /** Events (for events query) */
  events?: SubagentEventInfo[];
  /** Logs (for logs query) */
  logs?: SubagentLogInfo[];
  /** Final output (for output query) */
  output?: string;
  /** Error message if query failed */
  error?: string;
}

/**
 * Callback to query a subagent (provided by orchestrator)
 */
export type QuerySubagentCallback = (
  sessionId: string,
  queryType: SubagentQueryType,
  limit?: number
) => Promise<QuerySubagentResult>;

/**
 * Configuration for QuerySubagentTool
 */
export interface QuerySubagentToolConfig {
  /** Callback to query the subagent */
  onQuery: QuerySubagentCallback;
}

/**
 * Tool for querying sub-agent status, events, logs, or output
 */
export class QuerySubagentTool implements TronTool<QuerySubagentParams> {
  readonly name = 'QuerySubagent';
  readonly description = `Query the status, events, logs, or output of a spawned sub-agent.

Query types:
- **status**: Get current status (running/completed/failed), turn count, token usage, and task
- **events**: Get recent events from the sub-agent session
- **logs**: Get log entries from the sub-agent session
- **output**: Get the final assistant response (only available when completed)

Use this to monitor sub-agents you've spawned with SpawnSubagent or SpawnTmuxAgent.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      sessionId: {
        type: 'string' as const,
        description: 'Session ID of the sub-agent to query (returned by SpawnSubagent/SpawnTmuxAgent).',
      },
      queryType: {
        type: 'string' as const,
        enum: ['status', 'events', 'logs', 'output'],
        description: 'Type of query: status, events, logs, or output.',
      },
      limit: {
        type: 'number' as const,
        description: 'Limit number of results for events/logs queries. Default: 20.',
      },
    },
    required: ['sessionId', 'queryType'] as string[],
  };

  readonly category = 'custom' as const;
  readonly label = 'Query Sub-Agent';

  private config: QuerySubagentToolConfig;

  constructor(config: QuerySubagentToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallIdOrArgs: string | Record<string, unknown>,
    argsOrSignal?: Record<string, unknown> | AbortSignal,
    _signal?: AbortSignal
  ): Promise<TronToolResult<QuerySubagentResult>> {
    // Handle both old and new signatures
    let args: Record<string, unknown>;

    if (typeof toolCallIdOrArgs === 'string') {
      // New signature: (toolCallId, params, signal)
      args = argsOrSignal as Record<string, unknown>;
    } else {
      // Old signature: (params)
      args = toolCallIdOrArgs;
    }

    const sessionId = args.sessionId as string;
    const queryType = args.queryType as SubagentQueryType;
    const limit = args.limit as number | undefined;

    // Validate required parameters
    if (!sessionId || typeof sessionId !== 'string') {
      return {
        content: 'Error: Missing required parameter "sessionId".',
        isError: true,
        details: { success: false, error: 'Missing sessionId parameter' },
      };
    }

    if (!queryType || !['status', 'events', 'logs', 'output'].includes(queryType)) {
      return {
        content: 'Error: Invalid queryType. Must be one of: status, events, logs, output.',
        isError: true,
        details: { success: false, error: 'Invalid queryType parameter' },
      };
    }

    logger.debug('Querying subagent', { sessionId, queryType, limit });

    try {
      const result = await this.config.onQuery(sessionId, queryType, limit ?? 20);

      if (!result.success) {
        return {
          content: `Failed to query sub-agent: ${result.error ?? 'Unknown error'}`,
          isError: true,
          details: result,
        };
      }

      // Format response based on query type
      let content: string;

      switch (queryType) {
        case 'status':
          content = this.formatStatus(result.status!);
          break;
        case 'events':
          content = this.formatEvents(result.events ?? []);
          break;
        case 'logs':
          content = this.formatLogs(result.logs ?? []);
          break;
        case 'output':
          content = result.output
            ? `**Sub-agent Output**:\n\n${result.output}`
            : 'Sub-agent has no output yet (may still be running or has no response).';
          break;
        default:
          content = 'Unknown query type';
      }

      return {
        content,
        isError: false,
        details: result,
      };
    } catch (error) {
      const err = error as Error;
      logger.error('Error querying subagent', { sessionId, queryType, error: err.message });

      return {
        content: `Error querying sub-agent: ${err.message}`,
        isError: true,
        details: { success: false, error: err.message },
      };
    }
  }

  private formatStatus(status: SubagentStatusInfo): string {
    const statusIcon = {
      running: '🔄',
      completed: '✅',
      failed: '❌',
      unknown: '❓',
    }[status.status];

    let output = `**Sub-agent Status** ${statusIcon}

| Property | Value |
|----------|-------|
| **Session ID** | \`${status.sessionId}\` |
| **Status** | ${status.status} |
| **Spawn Type** | ${status.spawnType ?? 'unknown'} |
| **Model** | ${status.model} |
| **Turns** | ${status.turnCount} |
| **Tokens** | ${status.inputTokens.toLocaleString()} in / ${status.outputTokens.toLocaleString()} out |
| **Cost** | $${status.cost.toFixed(4)} |
| **Working Dir** | \`${status.workingDirectory}\` |
| **Created** | ${status.createdAt} |
| **Last Activity** | ${status.lastActivityAt} |`;

    if (status.endedAt) {
      output += `\n| **Ended** | ${status.endedAt} |`;
    }

    if (status.tmuxSessionName) {
      output += `\n| **Tmux Session** | \`${status.tmuxSessionName}\` |`;
    }

    if (status.task) {
      const taskPreview = status.task.length > 100
        ? status.task.slice(0, 100) + '...'
        : status.task;
      output += `\n\n**Task**: ${taskPreview}`;
    }

    return output;
  }

  private formatEvents(events: SubagentEventInfo[]): string {
    if (events.length === 0) {
      return 'No events found for this sub-agent.';
    }

    let output = `**Sub-agent Events** (${events.length} events)\n\n`;

    for (const event of events) {
      output += `- \`${event.timestamp}\` **${event.type}**: ${event.summary}\n`;
    }

    return output;
  }

  private formatLogs(logs: SubagentLogInfo[]): string {
    if (logs.length === 0) {
      return 'No log entries found for this sub-agent.';
    }

    let output = `**Sub-agent Logs** (${logs.length} entries)\n\n`;

    for (const log of logs) {
      const levelIcon = {
        error: '❌',
        warn: '⚠️',
        info: 'ℹ️',
        debug: '🔍',
      }[log.level] ?? '📝';

      output += `${levelIcon} \`${log.timestamp}\` [${log.component}] ${log.message}\n`;
    }

    return output;
  }
}
