/**
 * @fileoverview Sub-Agent Operations Module
 *
 * Exports all sub-agent operations components.
 */

// Types
export type {
  SubagentOperationsConfig,
  SpawnSubagentResult,
  SpawnTmuxAgentResult,
  QuerySubagentResult,
  WaitForSubagentsResult,
} from './types.js';

// Handlers (for direct use or testing)
export {
  SpawnHandler,
  createSpawnHandler,
  type SpawnHandlerDeps,
} from './spawn-handler.js';

export {
  QueryHandler,
  createQueryHandler,
  type QueryHandlerDeps,
} from './query-handler.js';

// Results builder (stateless function)
export { buildSubagentResultsContext } from './results-builder.js';

// Main facade
export {
  SubagentOperations,
  createSubagentOperations,
} from './subagent-ops.js';
