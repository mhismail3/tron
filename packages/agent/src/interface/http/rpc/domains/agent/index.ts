/**
 * @fileoverview Agent domain - Agent lifecycle and execution
 *
 * Handles agent prompts, abort, and state queries.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleAgentPrompt,
  handleAgentAbort,
  handleAgentGetState,
  createAgentHandlers,
} from '../../../../rpc/handlers/agent.handler.js';

// Re-export types
export type {
  AgentPromptParams,
  AgentPromptResult,
  AgentAbortParams,
  AgentAbortResult,
  AgentGetStateParams,
  AgentGetStateResult,
} from '../../../../rpc/types/agent.js';
