/**
 * @fileoverview Agent module exports
 */

// Public types
export * from './types.js';

// Main agent class
export { TronAgent } from './tron-agent.js';

// Extracted modules (for advanced use cases or testing)
export {
  AgentEventEmitter,
  createEventEmitter,
} from './event-emitter.js';

export {
  AgentToolExecutor,
  createToolExecutor,
} from './tool-executor.js';

export {
  AgentStreamProcessor,
  createStreamProcessor,
} from './stream-processor.js';

export {
  AgentCompactionHandler,
  createCompactionHandler,
} from './compaction-handler.js';

export {
  AgentTurnRunner,
  createTurnRunner,
} from './turn-runner.js';

// Internal types are NOT exported - they are for internal module communication only
