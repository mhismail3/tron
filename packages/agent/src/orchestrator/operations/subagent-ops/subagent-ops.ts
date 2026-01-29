/**
 * @fileoverview Sub-Agent Operations Facade
 *
 * Coordinates sub-agent operations by delegating to focused handlers.
 * This is a facade that maintains API compatibility while the implementation
 * is split into specialized handlers.
 *
 * ## Operations
 *
 * - **spawnSubsession**: Spawn an in-process sub-agent (via SpawnHandler)
 * - **spawnTmuxAgent**: Spawn an out-of-process sub-agent in tmux (via SpawnHandler)
 * - **querySubagent**: Query sub-agent status, events, logs, or output (via QueryHandler)
 * - **buildSubagentResultsContext**: Format pending results for injection (via results-builder)
 *
 * ## Design
 *
 * - Facade pattern: Delegates to specialized handlers
 * - Maintains backward compatibility with existing API
 * - Handlers are independently testable
 */
import type { SpawnSubagentParams } from '../../../tools/subagent/index.js';
import type { SubagentQueryType } from '../../../tools/subagent/index.js';
import type { ActiveSession } from '../../types.js';
import type {
  SubagentOperationsConfig,
  SpawnSubagentResult,
  SpawnTmuxAgentResult,
  QuerySubagentResult,
} from './types.js';
import { SpawnHandler, createSpawnHandler } from './spawn-handler.js';
import { QueryHandler, createQueryHandler } from './query-handler.js';
import { buildSubagentResultsContext as buildResultsContext } from './results-builder.js';

// =============================================================================
// SubagentOperations Class
// =============================================================================

/**
 * Handles all sub-agent operations for the orchestrator.
 * Facade that delegates to specialized handlers.
 */
export class SubagentOperations {
  private spawnHandler: SpawnHandler;
  private queryHandler: QueryHandler;

  constructor(config: SubagentOperationsConfig) {
    // Initialize spawn handler with full config
    this.spawnHandler = createSpawnHandler(config);

    // Initialize query handler with subset of config
    this.queryHandler = createQueryHandler({
      eventStore: config.eventStore,
      getActiveSession: config.getActiveSession,
    });
  }

  // ===========================================================================
  // Public Methods - Delegate to handlers
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
    return this.spawnHandler.spawnSubsession(parentSessionId, params, toolCallId);
  }

  /**
   * Spawn an out-of-process sub-agent in a tmux session.
   * The sub-agent runs independently with its own process.
   */
  async spawnTmuxAgent(
    parentSessionId: string,
    params: SpawnSubagentParams
  ): Promise<SpawnTmuxAgentResult> {
    return this.spawnHandler.spawnTmuxAgent(parentSessionId, params);
  }

  /**
   * Query a sub-agent's status, events, logs, or output.
   */
  async querySubagent(
    sessionId: string,
    queryType: SubagentQueryType,
    limit?: number
  ): Promise<QuerySubagentResult> {
    return this.queryHandler.querySubagent(sessionId, queryType, limit);
  }

  /**
   * Build context string for pending sub-agent results.
   * Consumes the pending results after formatting them.
   */
  buildSubagentResultsContext(active: ActiveSession): string | undefined {
    return buildResultsContext(active);
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
