/**
 * @fileoverview Wait For Subagent Tool
 *
 * Blocks until a spawned sub-agent completes, then returns the result.
 * Supports waiting for single or multiple sub-agents with timeout.
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import type { SubagentResult } from './subagent-tracker.js';
import { createLogger } from '../../logging/logger.js';

const logger = createLogger('tool:wait-for-subagent');

/**
 * Parameters for waiting on sub-agent(s)
 */
export interface WaitForSubagentParams {
  /** Session ID(s) of the sub-agent(s) to wait for */
  sessionIds: string[];
  /** How to wait when multiple IDs provided: 'all' or 'any' */
  mode?: 'all' | 'any';
  /** Maximum time to wait in milliseconds (default: 5 minutes) */
  timeout?: number;
}

/**
 * Result of waiting for sub-agent(s)
 */
export interface WaitForSubagentResult {
  /** Whether the wait was successful */
  success: boolean;
  /** Results from completed sub-agent(s) */
  results?: SubagentResult[];
  /** Error message if wait failed */
  error?: string;
  /** Whether timeout was reached */
  timedOut?: boolean;
}

/**
 * Callback to wait for sub-agent(s) (provided by orchestrator)
 */
export type WaitForSubagentCallback = (
  sessionIds: string[],
  mode: 'all' | 'any',
  timeout: number
) => Promise<WaitForSubagentResult>;

/**
 * Configuration for WaitForSubagentTool
 */
export interface WaitForSubagentToolConfig {
  /** Callback to perform the wait */
  onWait: WaitForSubagentCallback;
}

/**
 * Tool for waiting on sub-agent completion.
 *
 * Use this when you need the result of a sub-agent before continuing.
 * For fire-and-forget tasks where you don't need immediate results,
 * use SpawnSubagent/SpawnTmuxAgent without waiting.
 */
export class WaitForSubagentTool implements TronTool<WaitForSubagentParams> {
  readonly name = 'WaitForSubagent';
  readonly description = `Wait for spawned sub-agent(s) to complete and get their results.

Use this when you need the output of a sub-agent before proceeding. The tool will block until:
- The sub-agent(s) complete (success or failure)
- The timeout is reached (default: 5 minutes)

Parameters:
- **sessionIds**: Array of session IDs to wait for (can contain single ID)
- **mode**: When waiting for multiple IDs:
  - 'all' (default): Wait for ALL sub-agents to complete
  - 'any': Return as soon as ANY sub-agent completes
- **timeout**: Maximum wait time in milliseconds (default: 300000 = 5 minutes)

Returns the full result including output, token usage, and duration.

Example usage:
\`\`\`
// Wait for a single sub-agent
WaitForSubagent({ sessionIds: ["sess_abc123"] })

// Wait for multiple sub-agents to all complete
WaitForSubagent({ sessionIds: ["sess_abc", "sess_xyz"], mode: "all" })

// Wait for the first of multiple sub-agents to complete
WaitForSubagent({ sessionIds: ["sess_abc", "sess_xyz"], mode: "any" })
\`\`\``;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      sessionIds: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Session ID(s) of the sub-agent(s) to wait for. Can be a single ID in an array or multiple IDs.',
      },
      mode: {
        type: 'string' as const,
        enum: ['all', 'any'],
        description: 'When waiting for multiple: "all" waits for all to complete, "any" returns on first completion. Default: "all".',
      },
      timeout: {
        type: 'number' as const,
        description: 'Maximum time to wait in milliseconds. Default: 300000 (5 minutes).',
      },
    },
    required: ['sessionIds'] as string[],
  };

  readonly category = 'custom' as const;
  readonly label = 'Wait For Sub-Agent';

  private config: WaitForSubagentToolConfig;

  constructor(config: WaitForSubagentToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallIdOrArgs: string | Record<string, unknown>,
    argsOrSignal?: Record<string, unknown> | AbortSignal,
    _signal?: AbortSignal
  ): Promise<TronToolResult<WaitForSubagentResult>> {
    // Handle both old and new signatures
    let args: Record<string, unknown>;

    if (typeof toolCallIdOrArgs === 'string') {
      args = argsOrSignal as Record<string, unknown>;
    } else {
      args = toolCallIdOrArgs;
    }

    const sessionIds = args.sessionIds as string[];
    const mode = (args.mode as 'all' | 'any') || 'all';
    const timeout = (args.timeout as number) || 5 * 60 * 1000;

    // Validate
    if (sessionIds.length === 0) {
      return {
        content: 'Error: No session IDs provided.',
        isError: true,
        details: { success: false, error: 'No session IDs provided' },
      };
    }

    for (const id of sessionIds) {
      if (!id || typeof id !== 'string') {
        return {
          content: 'Error: Invalid session ID format.',
          isError: true,
          details: { success: false, error: 'Invalid session ID format' },
        };
      }
    }

    logger.info('Waiting for sub-agent(s)', {
      sessionIds,
      mode,
      timeout,
    });

    try {
      const result = await this.config.onWait(sessionIds, mode, timeout);

      if (!result.success) {
        const errMsg = result.timedOut
          ? `Timeout after ${timeout}ms waiting for sub-agent(s)`
          : result.error ?? 'Unknown error';

        return {
          content: `Failed to wait for sub-agent(s): ${errMsg}`,
          isError: true,
          details: result,
        };
      }

      // Format the response
      const results = result.results ?? [];
      let content = `**Sub-agent(s) Completed**\n\n`;

      for (const r of results) {
        const statusIcon = r.success ? '✅' : '❌';
        content += `### ${statusIcon} Session: \`${r.sessionId}\`\n\n`;
        content += `| Property | Value |\n`;
        content += `|----------|-------|\n`;
        content += `| **Status** | ${r.success ? 'Completed' : 'Failed'} |\n`;
        content += `| **Turns** | ${r.totalTurns} |\n`;
        content += `| **Tokens** | ${r.tokenUsage.inputTokens.toLocaleString()} in / ${r.tokenUsage.outputTokens.toLocaleString()} out |\n`;
        content += `| **Duration** | ${(r.duration / 1000).toFixed(1)}s |\n`;

        if (r.error) {
          content += `\n**Error**: ${r.error}\n`;
        }

        if (r.output) {
          const outputPreview = r.output.length > 1000
            ? r.output.slice(0, 1000) + '\n\n... (truncated, use QuerySubagent for full output)'
            : r.output;
          content += `\n**Output**:\n${outputPreview}\n`;
        }

        content += '\n---\n\n';
      }

      return {
        content,
        isError: false,
        details: result,
      };
    } catch (error) {
      const err = error as Error;
      logger.error('Error waiting for sub-agent(s)', { sessionIds, error: err.message });

      return {
        content: `Error waiting for sub-agent(s): ${err.message}`,
        isError: true,
        details: { success: false, error: err.message },
      };
    }
  }
}
